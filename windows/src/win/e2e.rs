//! `larynx e2e`: dictates into Notepad end to end, as a person would, and times it from the outside.
//!
//! It opens Notepad, starts the app with `--feed <wav>` (CI machines have no microphone, so the recording is played
//! in real time instead), holds Right Ctrl for as long as the recording lasts, lets go, and watches Notepad's text
//! until the words arrive. Also checked: Notepad keeps the focus the whole time (the pill never takes it), the pill
//! is on screen while talking, the clipboard holds what it held before, and Right Ctrl+C while talking cancels.
//!
//! For CI only: it drives the real desktop, so never run it on a desktop someone is using.

use super::focus;
use super::insert;
use crate::{wav, Args};
use std::io::{BufRead, Write};
use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};
use windows::core::{w, BOOL};
use windows::Win32::Foundation::{HWND, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::DataExchange::{CloseClipboard, GetClipboardData, OpenClipboard};
use windows::Win32::System::Memory::{GlobalLock, GlobalUnlock};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

fn key(vk: VIRTUAL_KEY, up: bool) {
    let mut flags = if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) };
    if vk == VK_RCONTROL || vk == VK_RMENU {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    let scan = unsafe { MapVirtualKeyW(vk.0 as u32, MAPVK_VK_TO_VSC) } as u16;
    let input = INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } };
    unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
}

unsafe extern "system" fn find_edit(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let class = focus::class_name(hwnd).to_ascii_lowercase();
    if class == "edit" || class.starts_with("richedit") {
        unsafe { *(lparam.0 as *mut HWND) = hwnd };
        return false.into();
    }
    true.into()
}

fn notepad_edit(notepad: HWND) -> Option<HWND> {
    let mut found = HWND::default();
    unsafe {
        let _ = EnumChildWindows(Some(notepad), Some(find_edit), LPARAM(&mut found as *mut HWND as isize));
    }
    (!found.is_invalid()).then_some(found)
}

fn clipboard_text() -> Option<String> {
    unsafe {
        OpenClipboard(None).ok()?;
        let text = GetClipboardData(13).ok().and_then(|h| {
            let g = windows::Win32::Foundation::HGLOBAL(h.0);
            let p = GlobalLock(g) as *const u16;
            if p.is_null() {
                return None;
            }
            let mut n = 0;
            while *p.add(n) != 0 {
                n += 1;
            }
            let s = String::from_utf16_lossy(std::slice::from_raw_parts(p, n));
            let _ = GlobalUnlock(g);
            Some(s)
        });
        let _ = CloseClipboard();
        text
    }
}

/// Saves the screen to a BMP (the pill, mid-dictation, for the record).
fn screenshot(path: &Path) -> Result<(), String> {
    unsafe {
        let (w, h) = (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let bmp = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(mem, HGDIOBJ(bmp.0));
        BitBlt(mem, 0, 0, w, h, Some(screen), 0, 0, SRCCOPY).map_err(|e| e.to_string())?;
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER { biSize: 40, biWidth: w, biHeight: h, biPlanes: 1, biBitCount: 32, biCompression: BI_RGB.0, ..Default::default() },
            ..Default::default()
        };
        let mut pixels = vec![0u8; (w * h * 4) as usize];
        GetDIBits(mem, bmp, 0, h as u32, Some(pixels.as_mut_ptr() as *mut _), &mut info, DIB_RGB_COLORS);
        SelectObject(mem, old);
        let _ = DeleteObject(HGDIOBJ(bmp.0));
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        let mut f = std::fs::File::create(path).map_err(|e| e.to_string())?;
        let size = 54 + pixels.len() as u32;
        let mut header = Vec::with_capacity(54);
        header.extend_from_slice(b"BM");
        header.extend_from_slice(&size.to_le_bytes());
        header.extend_from_slice(&0u32.to_le_bytes());
        header.extend_from_slice(&54u32.to_le_bytes());
        header.extend_from_slice(&40u32.to_le_bytes());
        header.extend_from_slice(&w.to_le_bytes());
        header.extend_from_slice(&h.to_le_bytes());
        header.extend_from_slice(&1u16.to_le_bytes());
        header.extend_from_slice(&32u16.to_le_bytes());
        header.extend_from_slice(&[0u8; 24]);
        f.write_all(&header).and_then(|_| f.write_all(&pixels)).map_err(|e| e.to_string())
    }
}

struct Kill(Vec<Child>);
impl Drop for Kill {
    fn drop(&mut self) {
        for c in &mut self.0 {
            let _ = c.kill();
        }
    }
}

fn wait_for(seconds: f64, mut f: impl FnMut() -> bool) -> Option<Duration> {
    let start = Instant::now();
    while start.elapsed().as_secs_f64() < seconds {
        if f() {
            return Some(start.elapsed());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    None
}

fn log_events(path: &Path) -> Vec<serde_json::Value> {
    std::fs::File::open(path)
        .map(|f| std::io::BufReader::new(f).lines().map_while(Result::ok).filter_map(|l| serde_json::from_str(&l).ok()).collect())
        .unwrap_or_default()
}

struct Check<'a> {
    notepad: HWND,
    edit: HWND,
    seconds: f64,
    expect: &'a [String],
    reject: &'a [String],
    out_dir: &'a Path,
}

impl Check<'_> {
    fn dictate(&self, label: &str, failures: &mut Vec<String>) -> serde_json::Value {
        if !insert::bring_back(self.notepad) {
            failures.push(format!("{label}: could not focus Notepad"));
        }
        std::thread::sleep(Duration::from_millis(300));
        let before = focus::window_text(self.edit).unwrap_or_default();
        key(VK_RCONTROL, false);
        std::thread::sleep(Duration::from_secs_f64(self.seconds / 2.0));
        let pill = unsafe { FindWindowW(w!("LarynxPill"), None) }.unwrap_or_default();
        let pill_visible = !pill.is_invalid() && unsafe { IsWindowVisible(pill).as_bool() };
        let mut pill_rect = RECT::default();
        unsafe {
            let _ = GetWindowRect(pill, &mut pill_rect);
        }
        let focus_mid = unsafe { GetForegroundWindow() } == self.notepad;
        if label == "first" {
            let _ = screenshot(&self.out_dir.join("pill.bmp"));
        }
        std::thread::sleep(Duration::from_secs_f64(self.seconds / 2.0 + 0.4));
        key(VK_RCONTROL, true);
        let up = Instant::now();
        let mut after = String::new();
        let arrived = wait_for(20.0, || {
            after = focus::window_text(self.edit).unwrap_or_default();
            after != before && self.expect.iter().all(|x| after.to_lowercase().contains(x))
        });
        let latency = arrived.map(|_| up.elapsed().as_secs_f64() * 1000.0);
        let focus_end = unsafe { GetForegroundWindow() } == self.notepad;
        std::thread::sleep(Duration::from_millis(900));
        let clipboard = clipboard_text();
        let restored = clipboard.as_deref() == Some("clipboard before dictation");
        let inserted = after.strip_prefix(&before).unwrap_or(&after).to_string();
        if latency.is_none() {
            failures.push(format!("{label}: the words never arrived in Notepad (it has {after:?})"));
        }
        for r in self.reject {
            if inserted.to_lowercase().split(|c: char| !c.is_alphanumeric()).any(|w| w == r) {
                failures.push(format!("{label}: {r:?} should have been cleaned out of {inserted:?}"));
            }
        }
        if !pill_visible {
            failures.push(format!("{label}: the pill was not on screen while talking"));
        }
        if !focus_mid || !focus_end {
            failures.push(format!("{label}: Notepad lost the focus"));
        }
        if !restored {
            failures.push(format!("{label}: the clipboard was not restored (it holds {clipboard:?})"));
        }
        serde_json::json!({
            "inserted": inserted, "key_up_to_text_in_notepad_ms": latency, "pill_visible": pill_visible,
            "pill_rect": [pill_rect.left, pill_rect.top, pill_rect.right, pill_rect.bottom],
            "notepad_kept_focus": focus_mid && focus_end, "clipboard_restored": restored,
        })
    }
}

pub fn run(args: &Args) -> Result<(), String> {
    let app = args.flag("app").map(str::to_string).unwrap_or_else(|| std::env::current_exe().unwrap().to_string_lossy().into_owned());
    let feed = args.flag("feed").ok_or("--feed <wav> is required")?;
    let split = |s: Option<&str>| -> Vec<String> { s.unwrap_or_default().split('|').map(|s| s.to_lowercase()).filter(|s| !s.is_empty()).collect() };
    let (expect, reject) = (split(args.flag("expect")), split(args.flag("reject")));
    let out_dir = Path::new(args.flag("out").unwrap_or("e2e"));
    std::fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;
    let log = out_dir.join("app.jsonl");
    let _ = std::fs::remove_file(&log);
    let seconds = wav::read(Path::new(feed))?.len() as f64 / wav::RATE as f64;
    let mut failures: Vec<String> = Vec::new();
    let mut report = serde_json::Map::new();

    // The clipboard before: it must be there again after the dictation.
    insert::copy_only("clipboard before dictation");

    let mut children = Kill(Vec::new());
    children.0.push(Command::new("notepad.exe").spawn().map_err(|e| format!("notepad: {e}"))?);
    let mut notepad = HWND::default();
    wait_for(15.0, || {
        notepad = unsafe { FindWindowW(w!("Notepad"), None) }.unwrap_or_default();
        !notepad.is_invalid()
    })
    .ok_or("Notepad's window never appeared")?;
    let edit = wait_for(10.0, || notepad_edit(notepad).is_some()).and_then(|_| notepad_edit(notepad)).ok_or("no text box in Notepad")?;
    report.insert("notepad_edit_class".into(), focus::class_name(edit).into());

    let mut cmd = Command::new(&app);
    cmd.args(["run", "--feed", feed, "--log"]).arg(&log);
    for flag in ["model", "provider", "threads"] {
        if let Some(v) = args.flag(flag) {
            cmd.args([format!("--{flag}").as_str(), v]);
        }
    }
    children.0.push(cmd.spawn().map_err(|e| format!("{app}: {e}"))?);
    let ready = wait_for(300.0, || log_events(&log).iter().any(|e| e["event"] == "ready" || e["event"] == "error"));
    if let Some(e) = log_events(&log).iter().find(|e| e["event"] == "error") {
        return Err(format!("the app could not start: {e}"));
    }
    report.insert("app_ready_s".into(), ready.map(|d| d.as_secs_f64()).into());
    if ready.is_none() {
        return Err("the app never became ready".into());
    }

    let check = Check { notepad, edit, seconds, expect: &expect, reject: &reject, out_dir };
    let first = check.dictate("first", &mut failures);
    report.insert("first".into(), first);
    let second = check.dictate("second", &mut failures);
    report.insert("second".into(), second);

    // Right Ctrl+C while holding: a shortcut, not a dictation. Nothing may be typed.
    let before = focus::window_text(edit).unwrap_or_default();
    key(VK_RCONTROL, false);
    std::thread::sleep(Duration::from_millis(700));
    key(VK_C, false);
    key(VK_C, true);
    std::thread::sleep(Duration::from_millis(400));
    key(VK_RCONTROL, true);
    std::thread::sleep(Duration::from_secs(3));
    let cancelled = focus::window_text(edit).unwrap_or_default() == before;
    if !cancelled {
        failures.push("Right Ctrl+C while talking still typed something".into());
    }
    report.insert("shortcut_cancels".into(), cancelled.into());

    let events: Vec<serde_json::Value> = log_events(&log).into_iter().filter(|e| e["event"] != "key_down").collect();
    report.insert("app_log".into(), events.into());
    report.insert("failures".into(), failures.clone().into());
    let json = serde_json::to_string_pretty(&serde_json::Value::Object(report)).unwrap();
    println!("{json}");
    std::fs::write(out_dir.join("e2e.json"), json).map_err(|e| e.to_string())?;
    drop(children);
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}
