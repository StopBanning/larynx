//! The welcome window: what someone sees when they start Larynx. The tray icon alone is easy to miss (Windows often
//! hides it behind the ^), and the first start downloads a 670 MB model, so without this a first start looks like
//! nothing happened.
//!
//!   downloading (one time only, with a progress bar) -> loading -> ready: how to talk, and a box to try it in
//!   any of those -> failed: what went wrong, in words, and what to do
//!
//! It opens on every start that a person made (not the tests' `--feed` runs), from the tray icon, and when Larynx is
//! started while it is already running. Closing it leaves Larynx running. Everything here runs on the UI thread.

use super::meeting::{font, scale};
use super::tray::make_icon;
use std::cell::RefCell;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::*;

pub const CLASS: PCWSTR = w!("LarynxWelcome");
const ID_TRY: usize = 300;

#[derive(Clone, PartialEq)]
pub enum State {
    Downloading { done: u64, total: u64 },
    Loading,
    Ready,
    Failed(String),
}

struct Inner {
    hwnd: HWND,
    edit: HWND,
    state: State,
    key: String,
    title: HFONT,
    heading: HFONT,
    body: HFONT,
    small: HFONT,
    icon: HICON,
}

thread_local! {
    static WELCOME: RefCell<Option<Inner>> = const { RefCell::new(None) };
}

const BG: COLORREF = COLORREF(0x00FFFFFF);
const INK: COLORREF = COLORREF(0x00241E1A);
const MUTED: COLORREF = COLORREF(0x00756B64);
const BLUE: COLORREF = COLORREF(0x00FF8440); // #4084FF, the tray icon's blue
const TRACK: COLORREF = COLORREF(0x00F2EAE6);
const RED: COLORREF = COLORREF(0x002A2AC0);

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// The window's size at 100% scaling.
const W: i32 = 560;
const H: i32 = 500;

/// Opens the window (or brings it forward) showing `state`. `key` is the talk key's name ("Right Ctrl").
pub fn open(key: &str, state: State) {
    let existing = WELCOME.with(|w| w.borrow().as_ref().map(|i| i.hwnd));
    let hwnd = match existing {
        Some(h) => h,
        None => match create(key, state.clone()) {
            Some(h) => h,
            None => return,
        },
    };
    set(state);
    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOWNORMAL);
        let _ = SetForegroundWindow(hwnd);
    }
    focus_try_box();
}

pub fn is_open() -> bool {
    WELCOME.with(|w| w.borrow().is_some())
}

/// Changes what the window shows, if it is open. Leaves it closed if it isn't.
pub fn set(state: State) {
    let changed = WELCOME.with(|w| {
        let mut w = w.borrow_mut();
        let Some(i) = w.as_mut() else { return None };
        if i.state == state {
            return None;
        }
        let became_ready = state == State::Ready && i.state != State::Ready;
        i.state = state;
        Some((i.hwnd, i.edit, became_ready, i.state == State::Ready))
    });
    let Some((hwnd, edit, became_ready, ready)) = changed else { return };
    unsafe {
        let _ = ShowWindow(edit, if ready { SW_SHOW } else { SW_HIDE });
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
    if became_ready {
        // Ready is the moment to look: bring the window forward and put the cursor in the box.
        unsafe {
            if IsWindowVisible(hwnd).as_bool() {
                let _ = SetForegroundWindow(hwnd);
            }
        }
        focus_try_box();
    }
}

fn focus_try_box() {
    let target = WELCOME.with(|w| w.borrow().as_ref().filter(|i| i.state == State::Ready).map(|i| i.edit));
    if let Some(edit) = target {
        unsafe {
            let _ = SetFocus(Some(edit));
        }
    }
}

fn create(key: &str, state: State) -> Option<HWND> {
    unsafe {
        let instance = GetModuleHandleW(None).ok()?;
        let class = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(proc),
            hInstance: instance.into(),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            lpszClassName: CLASS,
            ..Default::default()
        };
        RegisterClassExW(&class);
        let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        // The outer size that gives this client size, centred on the main screen.
        let mut r = RECT { left: 0, top: 0, right: scale(W), bottom: scale(H) };
        let _ = AdjustWindowRectEx(&mut r, style, false, WINDOW_EX_STYLE(0));
        let (ow, oh) = (r.right - r.left, r.bottom - r.top);
        let (sw, sh) = (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            CLASS,
            w!("Larynx"),
            style,
            ((sw - ow) / 2).max(0),
            ((sh - oh) / 2).max(0),
            ow,
            oh,
            None,
            None,
            Some(instance.into()),
            None,
        )
        .ok()?;
        let icon = make_icon(64, false);
        let _ = SendMessageW(hwnd, WM_SETICON, Some(WPARAM(ICON_BIG as usize)), Some(LPARAM(icon.0 as isize)));
        let _ = SendMessageW(hwnd, WM_SETICON, Some(WPARAM(ICON_SMALL as usize)), Some(LPARAM(make_icon(16, false).0 as isize)));
        let body = font(15, FW_NORMAL);
        let (x, y, ew, eh) = edit_rect();
        let edit = CreateWindowExW(
            WS_EX_CLIENTEDGE,
            w!("EDIT"),
            w!(""),
            WS_CHILD | WS_TABSTOP | WS_VSCROLL | WINDOW_STYLE((ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN) as u32),
            x,
            y,
            ew,
            eh,
            Some(hwnd),
            Some(HMENU(ID_TRY as *mut _)),
            Some(instance.into()),
            None,
        )
        .unwrap_or_default();
        let _ = SendMessageW(edit, WM_SETFONT, Some(WPARAM(body.0 as usize)), Some(LPARAM(1)));
        let ready = state == State::Ready;
        WELCOME.with(|w| {
            *w.borrow_mut() = Some(Inner {
                hwnd,
                edit,
                state,
                key: key.to_string(),
                title: font(26, FW_SEMIBOLD),
                heading: font(19, FW_SEMIBOLD),
                body,
                small: font(13, FW_NORMAL),
                icon,
            })
        });
        let _ = ShowWindow(edit, if ready { SW_SHOW } else { SW_HIDE });
        Some(hwnd)
    }
}

/// Where the practice box sits (client coordinates).
fn edit_rect() -> (i32, i32, i32, i32) {
    (scale(32), scale(330), scale(W - 64), scale(92))
}

fn mb(bytes: u64) -> u64 {
    (bytes + 500_000) / 1_000_000
}

/// The words for each state: heading, body, and the line at the bottom.
fn words(state: &State, key: &str) -> (String, String, String) {
    let tray = "Larynx lives in the tray, by the clock (click ^ if its blue icon is hidden). You can close this window; Larynx keeps running.".to_string();
    match state {
        State::Downloading { done, total } => (
            "Getting ready (one time only)".into(),
            format!(
                "Downloading the speech model: {} of {} MB. This can take a few minutes. After this, Larynx works without the internet, and what you say never leaves this PC.",
                mb(*done),
                mb(*total)
            ),
            tray,
        ),
        State::Loading => (
            "Almost ready".into(),
            "Loading the speech model. This takes a few seconds.".into(),
            tray,
        ),
        State::Ready => (
            format!("Ready. Hold {key} and talk."),
            format!(
                "1.  Click where you want the words to go, in any app.\n2.  Hold the {key} key while you talk.\n3.  Let go. Your words appear, with the ums taken out.\n\nTry it in this box:"
            ),
            tray,
        ),
        State::Failed(why) => (
            "Something went wrong".into(),
            why.clone(),
            "Start Larynx again to try again. If it keeps happening, the tray menu has \u{201c}Send a report\u{2026}\u{201d}.".into(),
        ),
    }
}

unsafe fn paint(i: &Inner) {
    let mut ps = PAINTSTRUCT::default();
    let screen = BeginPaint(i.hwnd, &mut ps);
    let mut client = RECT::default();
    let _ = GetClientRect(i.hwnd, &mut client);
    let (cw, ch) = (client.right, client.bottom);
    // Drawn off screen first, so the progress bar doesn't flicker as it moves.
    let dc = CreateCompatibleDC(Some(screen));
    let bmp = CreateCompatibleBitmap(screen, cw, ch);
    let old_bmp = SelectObject(dc, HGDIOBJ(bmp.0));
    let bg = CreateSolidBrush(BG);
    FillRect(dc, &client, bg);
    let _ = DeleteObject(HGDIOBJ(bg.0));
    SetBkMode(dc, TRANSPARENT);

    let pad = scale(32);
    let _ = DrawIconEx(dc, pad, scale(28), i.icon, scale(48), scale(48), 0, None, DI_NORMAL);
    let text = |f: HFONT, color: COLORREF, s: &str, r: &mut RECT, flags: DRAW_TEXT_FORMAT| -> i32 {
        SelectObject(dc, HGDIOBJ(f.0));
        SetTextColor(dc, color);
        let mut wtext = wide(s);
        if wtext.is_empty() {
            return 0;
        }
        DrawTextW(dc, &mut wtext, r, flags)
    };
    let mut r = RECT { left: pad + scale(64), top: scale(26), right: cw - pad, bottom: scale(62) };
    text(i.title, INK, "Larynx", &mut r, DT_SINGLELINE | DT_LEFT | DT_TOP);
    let mut r = RECT { left: pad + scale(64), top: scale(60), right: cw - pad, bottom: scale(84) };
    text(i.small, MUTED, "Talk instead of type. Everything stays on this PC.", &mut r, DT_SINGLELINE | DT_LEFT | DT_TOP);

    let (heading, body, foot) = words(&i.state, &i.key);
    let mut top = scale(108);
    let mut r = RECT { left: pad, top, right: cw - pad, bottom: top + scale(30) };
    text(i.heading, if matches!(i.state, State::Failed(_)) { RED } else { INK }, &heading, &mut r, DT_SINGLELINE | DT_LEFT | DT_TOP);
    top += scale(40);
    let mut r = RECT { left: pad, top, right: cw - pad, bottom: ch - scale(70) };
    // Measure, then draw, so whatever follows sits just under the text.
    let mut measure = r;
    let height = text(i.body, INK, &body, &mut measure, DT_WORDBREAK | DT_LEFT | DT_TOP | DT_CALCRECT);
    text(i.body, INK, &body, &mut r, DT_WORDBREAK | DT_LEFT | DT_TOP);
    top += height + scale(18);

    match &i.state {
        State::Downloading { done, total } => {
            let (x0, x1, h) = (pad, cw - pad, scale(10));
            let frac = if *total > 0 { (*done as f64 / *total as f64).clamp(0.0, 1.0) } else { 0.0 };
            let no_pen = GetStockObject(NULL_PEN);
            let old_pen = SelectObject(dc, no_pen);
            for (color, right) in [(TRACK, x1), (BLUE, x0 + ((x1 - x0) as f64 * frac) as i32)] {
                if right <= x0 {
                    continue;
                }
                let b = CreateSolidBrush(color);
                let old = SelectObject(dc, HGDIOBJ(b.0));
                let _ = RoundRect(dc, x0, top, right.max(x0 + h), top + h, h, h);
                SelectObject(dc, old);
                let _ = DeleteObject(HGDIOBJ(b.0));
            }
            SelectObject(dc, old_pen);
            let mut r = RECT { left: pad, top: top + scale(18), right: cw - pad, bottom: top + scale(40) };
            text(i.small, MUTED, &format!("{}%", (frac * 100.0).round() as u32), &mut r, DT_SINGLELINE | DT_LEFT | DT_TOP);
        }
        State::Ready => {
            // The practice box follows the instructions.
            let (x, _, ew, eh) = edit_rect();
            let _ = MoveWindow(i.edit, x, top, ew, eh, true);
        }
        _ => {}
    }

    let mut r = RECT { left: pad, top: ch - scale(62), right: cw - pad, bottom: ch - scale(14) };
    text(i.small, MUTED, &foot, &mut r, DT_WORDBREAK | DT_LEFT | DT_TOP);

    let _ = BitBlt(screen, 0, 0, cw, ch, Some(dc), 0, 0, SRCCOPY);
    SelectObject(dc, old_bmp);
    let _ = DeleteObject(HGDIOBJ(bmp.0));
    let _ = DeleteDC(dc);
    let _ = EndPaint(i.hwnd, &ps);
}

unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_ERASEBKGND => LRESULT(1),
        WM_PAINT => {
            let painted = WELCOME.with(|w| {
                if let Ok(w) = w.try_borrow() {
                    if let Some(i) = w.as_ref().filter(|i| i.hwnd == hwnd) {
                        unsafe { paint(i) };
                        return true;
                    }
                }
                false
            });
            if painted {
                LRESULT(0)
            } else {
                unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
            }
        }
        WM_CTLCOLOREDIT => {
            // The practice box: dark text on white, like the rest of the window.
            let dc = HDC(wparam.0 as *mut _);
            unsafe {
                SetTextColor(dc, INK);
                SetBkColor(dc, BG);
            }
            LRESULT(unsafe { GetStockObject(WHITE_BRUSH) }.0 as isize)
        }
        WM_DESTROY => {
            // Taken out before it is dropped, so nothing else can borrow it mid-drop.
            let gone = WELCOME.with(|w| w.borrow_mut().take());
            if let Some(i) = gone {
                unsafe {
                    for f in [i.title, i.heading, i.body, i.small] {
                        let _ = DeleteObject(HGDIOBJ(f.0));
                    }
                    let _ = DestroyIcon(i.icon);
                }
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_words_say_what_is_happening() {
        let (h, b, _) = words(&State::Downloading { done: 312_400_000, total: 670_619_803 }, "Right Ctrl");
        assert!(h.contains("one time only"));
        assert!(b.contains("312 of 671 MB"), "{b}");
        let (h, b, _) = words(&State::Ready, "Right Ctrl");
        assert_eq!(h, "Ready. Hold Right Ctrl and talk.");
        assert!(b.contains("Hold the Right Ctrl key"));
        let (h, b, foot) = words(&State::Failed("Couldn't download the speech model.".into()), "Right Ctrl");
        assert_eq!(h, "Something went wrong");
        assert!(b.starts_with("Couldn't download"));
        assert!(foot.contains("Send a report"));
    }
}
