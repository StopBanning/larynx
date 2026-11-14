//! Puts the words where the cursor is, the way the Mac's Inserter does: bring the app back if you switched away,
//! paste through the clipboard (marked so clipboard history and cloud clipboard skip it), check that the field
//! changed, fall back to typing the characters, and if nothing worked leave the words on the clipboard. The old
//! clipboard comes back afterwards unless something else was copied meanwhile.

use super::focus::{self, Target, Uia};
use std::time::{Duration, Instant};
use windows::core::w;
use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::*;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// Marks our own synthetic keys, so the talk-key hook ignores them.
pub const OURS: usize = 0x4C41_5259; // "LARY"

const CF_UNICODETEXT: u32 = 13;

#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "how", content = "detail", rename_all = "kebab-case")]
pub enum Delivery {
    Inserted,
    InsertedBy(String),
    PastedAndCopied(String),
    Copied(String),
}

pub struct Report {
    pub delivery: Delivery,
    /// From the start of delivery to Ctrl+V sent (ms).
    pub paste_sent_ms: f64,
    /// From the start of delivery to the field showing the words (ms), when it could be read.
    pub confirmed_ms: Option<f64>,
}

fn open_clipboard() -> bool {
    for _ in 0..20 {
        if unsafe { OpenClipboard(None) }.is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

/// Everything on the clipboard that is plain memory (text, HTML, files, DIB images...). GDI handles are skipped;
/// Windows rebuilds bitmaps from the DIB.
fn save_clipboard() -> Vec<(u32, Vec<u8>)> {
    let mut saved = Vec::new();
    if !open_clipboard() {
        return saved;
    }
    unsafe {
        let mut format = 0;
        loop {
            format = EnumClipboardFormats(format);
            if format == 0 {
                break;
            }
            // CF_BITMAP, METAFILEPICT, PALETTE, ENHMETAFILE, OWNERDISPLAY, DSP*, GDIOBJ range: not HGLOBALs.
            if matches!(format, 2 | 3 | 9 | 14 | 0x80 | 0x82 | 0x83 | 0x8E) || (0x300..=0x3FF).contains(&format) {
                continue;
            }
            if let Ok(h) = GetClipboardData(format) {
                let g = HGLOBAL(h.0);
                let size = GlobalSize(g);
                let p = GlobalLock(g) as *const u8;
                if !p.is_null() && size > 0 && size < 64 * 1024 * 1024 {
                    saved.push((format, std::slice::from_raw_parts(p, size).to_vec()));
                }
                let _ = GlobalUnlock(g);
            }
        }
        let _ = CloseClipboard();
    }
    saved
}

fn global(bytes: &[u8]) -> Option<HANDLE> {
    unsafe {
        let g = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)).ok()?;
        let p = GlobalLock(g) as *mut u8;
        if p.is_null() {
            return None;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p, bytes.len());
        let _ = GlobalUnlock(g);
        Some(HANDLE(g.0))
    }
}

fn utf16z(s: &str) -> Vec<u8> {
    s.encode_utf16().chain(std::iter::once(0)).flat_map(|u| u.to_le_bytes()).collect()
}

/// Puts `text` on the clipboard. `transient`: also tell clipboard history and cloud clipboard to leave it out.
fn set_clipboard(text: &str, transient: bool) -> bool {
    if !open_clipboard() {
        return false;
    }
    unsafe {
        let _ = EmptyClipboard();
        let ok = global(&utf16z(text)).map(|h| SetClipboardData(CF_UNICODETEXT, Some(h)).is_ok()).unwrap_or(false);
        if transient {
            let exclude = RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing"));
            let history = RegisterClipboardFormatW(w!("CanIncludeInClipboardHistory"));
            let cloud = RegisterClipboardFormatW(w!("CanUploadToCloudClipboard"));
            if let Some(h) = global(&[0]) {
                let _ = SetClipboardData(exclude, Some(h));
            }
            for f in [history, cloud] {
                if let Some(h) = global(&0u32.to_le_bytes()) {
                    let _ = SetClipboardData(f, Some(h));
                }
            }
        }
        let _ = CloseClipboard();
        ok
    }
}

fn restore_clipboard(saved: &[(u32, Vec<u8>)]) {
    if !open_clipboard() {
        return;
    }
    unsafe {
        let _ = EmptyClipboard();
        for (format, bytes) in saved {
            if let Some(h) = global(bytes) {
                let _ = SetClipboardData(*format, Some(h));
            }
        }
        let _ = CloseClipboard();
    }
}

/// Leaves the words on the clipboard for the user to paste (written normally, so it shows in history).
pub fn copy_only(text: &str) {
    set_clipboard(text, false);
}

fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
    let scan = unsafe { MapVirtualKeyW(vk.0 as u32, MAPVK_VK_TO_VSC) } as u16;
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) }, time: 0, dwExtraInfo: OURS },
        },
    }
}

fn unicode(unit: u16, up: bool) -> INPUT {
    let mut flags = KEYEVENTF_UNICODE;
    if up {
        flags |= KEYEVENTF_KEYUP;
    }
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(0), wScan: unit, dwFlags: flags, time: 0, dwExtraInfo: OURS } } }
}

/// Releases modifiers the user may still be holding (so Ctrl+V isn't Ctrl+Shift+V), then sends Ctrl+V.
fn send_paste() {
    let mut inputs = Vec::new();
    for vk in [VK_LSHIFT, VK_RSHIFT, VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN, VK_RCONTROL] {
        if unsafe { GetAsyncKeyState(vk.0 as i32) } < 0 {
            inputs.push(key(vk, true));
        }
    }
    inputs.extend([key(VK_LCONTROL, false), key(VK_V, false), key(VK_V, true), key(VK_LCONTROL, true)]);
    unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
}

/// Types the text as Unicode characters (no clipboard), for apps that ignore paste. Newlines become Enter.
pub fn type_text(text: &str) {
    let mut inputs = Vec::new();
    for line_or_break in text.split_inclusive('\n') {
        let (line, newline) = match line_or_break.strip_suffix('\n') {
            Some(l) => (l, true),
            None => (line_or_break, false),
        };
        for unit in line.trim_end_matches('\r').encode_utf16() {
            inputs.push(unicode(unit, false));
            inputs.push(unicode(unit, true));
        }
        if newline {
            inputs.push(key(VK_RETURN, false));
            inputs.push(key(VK_RETURN, true));
        }
    }
    for chunk in inputs.chunks(200) {
        unsafe { SendInput(chunk, std::mem::size_of::<INPUT>() as i32) };
    }
}

/// Brings `window` back to the front if the user switched away while talking. Windows only lets the app that got
/// the last input take the foreground, so a harmless key (an Alt tap marked as ours) is sent first, and the input
/// queues are joined for the moment of the switch.
pub fn bring_back(window: HWND) -> bool {
    unsafe {
        if GetForegroundWindow() == window {
            return true;
        }
        if IsIconic(window).as_bool() {
            let _ = ShowWindow(window, SW_RESTORE);
        }
        let fg_thread = GetWindowThreadProcessId(GetForegroundWindow(), None);
        let me = GetCurrentThreadId();
        let attached = fg_thread != me && AttachThreadInput(me, fg_thread, true).as_bool();
        SendInput(&[key(VK_MENU, false), key(VK_MENU, true)], std::mem::size_of::<INPUT>() as i32);
        let _ = SetForegroundWindow(window);
        let _ = BringWindowToTop(window);
        if attached {
            let _ = AttachThreadInput(me, fg_thread, false);
        }
        for _ in 0..8 {
            if GetForegroundWindow() == window {
                return true;
            }
            std::thread::sleep(Duration::from_millis(40));
        }
        GetForegroundWindow() == window
    }
}

enum Outcome {
    Changed,
    Unchanged,
    Unknown(&'static str),
}

/// Reads the field the way that works for it: UI Automation, or the window text of a classic Edit control.
fn read(uia: &Option<Uia>, hwnd: HWND) -> Option<(String, Option<windows::Win32::UI::Accessibility::IUIAutomationElement>)> {
    if let Some(u) = uia {
        let f = u.focused();
        if let Some(el) = f.element {
            if let Some(t) = u.text(&el) {
                return Some((t, Some(el)));
            }
        }
    }
    let class = focus::class_name(hwnd).to_ascii_lowercase();
    if class == "edit" || class.starts_with("richedit") {
        return focus::window_text(hwnd).map(|t| (t, None));
    }
    None
}

/// Polls every 30 ms for `seconds`: did the field's text change from `before`, or does a new field hold the words?
fn outcome(uia: &Option<Uia>, hwnd: HWND, before: &str, text: &str, seconds: f64, first_seen: &mut Option<Instant>) -> Outcome {
    let deadline = Instant::now() + Duration::from_secs_f64(seconds);
    let needle: String = text.trim().chars().take(60).collect();
    let mut result = Outcome::Unknown("unreadable");
    loop {
        if let Some((now, _)) = read(uia, hwnd) {
            if now != before {
                if now.contains(&needle) || needle.is_empty() {
                    first_seen.get_or_insert_with(Instant::now);
                    return Outcome::Changed;
                }
                // Changed but without our words (yet): keep watching until the deadline.
                result = Outcome::Unknown("changed-differently");
            } else {
                result = Outcome::Unchanged;
            }
        }
        if Instant::now() >= deadline {
            return result;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
}

/// Delivers `text` into `target`. Never inserts twice: only a field that is readable and provably unchanged gets
/// a second attempt.
pub fn deliver(text: &str, target: Option<Target>, uia: &Option<Uia>) -> Report {
    let start = Instant::now();
    let elapsed = |t: Instant| t.duration_since(start).as_secs_f64() * 1000.0;
    let report = |delivery: Delivery, sent: Option<Instant>, seen: Option<Instant>| Report {
        delivery,
        paste_sent_ms: sent.map(elapsed).unwrap_or(0.0),
        confirmed_ms: seen.map(elapsed),
    };
    if std::env::var("LARYNX_FORCE_COPY").as_deref() == Ok("1") {
        copy_only(text);
        return report(Delivery::Copied("LARYNX_FORCE_COPY is set".into()), None, None);
    }
    if let Some(t) = target {
        if !bring_back(t.window) {
            copy_only(text);
            return report(Delivery::Copied("could not bring the app back to the front".into()), None, None);
        }
    }
    let hwnd = focus::current().map(|t| t.focus).unwrap_or_default();
    let field = uia.as_ref().map(|u| u.focused());
    if field.as_ref().is_some_and(|f| f.password) {
        // Never type dictation into a password box; leave it on the clipboard instead, as the Mac does.
        copy_only(text);
        return report(Delivery::Copied("a password field has focus".into()), None, None);
    }
    if field.as_ref().is_some_and(|f| f.editable == Some(false)) {
        copy_only(text);
        return report(Delivery::Copied(format!("no text field has focus ({})", field.map(|f| f.kind).unwrap_or_default())), None, None);
    }
    let before = read(uia, hwnd).map(|r| r.0);
    let saved = save_clipboard();
    if !set_clipboard(text, true) {
        return report(Delivery::Copied("the clipboard is busy".into()), None, None);
    }
    let ours = unsafe { GetClipboardSequenceNumber() };
    if std::env::var("LARYNX_TEST_DROP_PASTE").as_deref() != Ok("1") {
        send_paste();
    }
    let sent = Instant::now();
    let restore = |saved: Vec<(u32, Vec<u8>)>| {
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(500));
            if unsafe { GetClipboardSequenceNumber() } == ours {
                restore_clipboard(&saved);
            }
        });
    };
    let Some(before) = before else {
        // Can't read the field: the paste was sent; keep the words on the clipboard too, one Ctrl+V away.
        copy_only(text);
        return report(Delivery::PastedAndCopied("field unreadable".into()), Some(sent), None);
    };
    let mut seen = None;
    match outcome(uia, hwnd, &before, text, 0.6, &mut seen) {
        Outcome::Changed => {
            restore(saved);
            return report(Delivery::Inserted, Some(sent), seen);
        }
        Outcome::Unknown(why) => {
            copy_only(text);
            return report(Delivery::PastedAndCopied(format!("paste {why}")), Some(sent), seen);
        }
        Outcome::Unchanged => {}
    }
    // The paste didn't arrive: type the characters instead.
    type_text(text);
    let typed = outcome(uia, hwnd, &before, text, 0.8, &mut seen);
    restore_clipboard(&saved);
    match typed {
        Outcome::Changed => report(Delivery::InsertedBy("typing".into()), Some(sent), seen),
        _ => {
            copy_only(text);
            report(Delivery::Copied("the paste didn't arrive in the field".into()), Some(sent), None)
        }
    }
}

