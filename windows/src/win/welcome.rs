//! The welcome window: what someone sees when they start Larynx. The tray icon alone is easy to miss (Windows often
//! hides it behind the ^), and the first start downloads a 670 MB model, so without this a first start looks like
//! nothing happened.
//!
//!   downloading (one time only, with a progress bar) -> loading -> ready: the cursor in a box to try it in
//!   any of those -> failed: what went wrong, in words, and what to do
//!
//! The look is the meeting panel's and Locust Glass's: the top of the window (and its title bar) on Windows' own
//! Acrylic under a dark tint, with the mark, the status and the progress; below it a solid sheet with how it works,
//! the practice box and where Larynx lives. The practice box is a standard Windows text box, which GDI draws without
//! alpha, so it sits on the solid part: on glass its text would come out see-through.
//!
//! It opens on every start that a person made (not the tests' `--feed` runs), from the tray icon, and when Larynx is
//! started while it is already running. Closing it leaves Larynx running. Everything here runs on the UI thread.

use super::glass::{self, palette, rect, rgba, round, Look};
use super::meeting::{font, scale};
use super::tray::app_icon;
use std::cell::{Cell, RefCell};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Direct2D::{ID2D1RenderTarget, ID2D1StrokeStyle, D2D1_DRAW_TEXT_OPTIONS_CLIP};
use windows::Win32::Graphics::DirectWrite::{DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_MEASURING_MODE_NATURAL};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::EM_SETMARGINS;
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
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
    look: Look,
    body_font: HFONT,
    icon_big: HICON,
    icon_small: HICON,
}

thread_local! {
    static WELCOME: RefCell<Option<Inner>> = const { RefCell::new(None) };
    /// The practice box's background, made once.
    static FIELD_BRUSH: Cell<isize> = const { Cell::new(0) };
}

/// The window's size at 100% scaling, and where the glass ends.
const W: f32 = 600.0;
const H: f32 = 620.0;
const HERO: f32 = 244.0;
const PAD: f32 = 32.0;
/// The practice box's frame (client coordinates at 100%).
const FIELD: (f32, f32, f32, f32) = (PAD, 430.0, W - PAD, 530.0);

/// The solid sheet under the glass, and the practice box in it (0x00BBGGRR for GDI, and the same in floats).
const SHEET: (f32, f32, f32) = (0.105, 0.112, 0.128);
const FIELD_RGB: (f32, f32, f32) = (0.145, 0.153, 0.172);
const FIELD_GDI: COLORREF = COLORREF(0x002C2725);
const FIELD_INK: COLORREF = COLORREF(0x00FAF7F5);
const BLUE: (f32, f32, f32) = (0.31, 0.65, 1.0); // the cursor's blue on the Larynx icon
const GREEN: (f32, f32, f32) = (0.30, 0.82, 0.48);

/// 100%-scaling pixels to this screen's.
fn px(v: f32) -> f32 {
    v * scale(960) as f32 / 960.0
}

fn ipx(v: f32) -> i32 {
    px(v).round() as i32
}

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

/// The talk key changed: the instructions name the new one.
pub fn set_key(key: &str) {
    let hwnd = WELCOME.with(|w| {
        let mut w = w.borrow_mut();
        let i = w.as_mut()?;
        i.key = key.to_string();
        Some(i.hwnd)
    });
    if let Some(h) = hwnd {
        unsafe {
            let _ = InvalidateRect(Some(h), None, false);
        }
    }
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
        let _ = EnableWindow(edit, ready);
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
        let mut r = RECT { left: 0, top: 0, right: ipx(W), bottom: ipx(H) };
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
        let look = glass::apply_top(hwnd, ipx(HERO));
        let (icon_big, icon_small) = (app_icon(ipx(32.0)), app_icon(ipx(16.0)));
        let _ = SendMessageW(hwnd, WM_SETICON, Some(WPARAM(ICON_BIG as usize)), Some(LPARAM(icon_big.0 as isize)));
        let _ = SendMessageW(hwnd, WM_SETICON, Some(WPARAM(ICON_SMALL as usize)), Some(LPARAM(icon_small.0 as isize)));
        let body_font = font(16, FW_NORMAL);
        let (x, y, ew, eh) = edit_rect();
        let edit = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("EDIT"),
            w!(""),
            WS_CHILD | WS_TABSTOP | WINDOW_STYLE((ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN) as u32),
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
        let _ = SendMessageW(edit, WM_SETFONT, Some(WPARAM(body_font.0 as usize)), Some(LPARAM(1)));
        // Some room inside the box, so the words don't touch its edge.
        let m = ipx(4.0) as usize;
        let _ = SendMessageW(edit, EM_SETMARGINS, Some(WPARAM((EC_LEFTMARGIN | EC_RIGHTMARGIN) as usize)), Some(LPARAM(((m << 16) | m) as isize)));
        let ready = state == State::Ready;
        WELCOME.with(|w| {
            *w.borrow_mut() = Some(Inner { hwnd, edit, state, key: key.to_string(), look, body_font, icon_big, icon_small })
        });
        let _ = EnableWindow(edit, ready);
        let _ = ShowWindow(edit, if ready { SW_SHOW } else { SW_HIDE });
        Some(hwnd)
    }
}

/// Where the text box sits inside the practice box's frame (client pixels).
fn edit_rect() -> (i32, i32, i32, i32) {
    let (l, t, r, b) = FIELD;
    (ipx(l + 14.0), ipx(t + 12.0), ipx(r - l - 28.0), ipx(b - t - 24.0))
}

fn mb(bytes: u64) -> u64 {
    (bytes + 500_000) / 1_000_000
}

/// The words for each state: the status heading and the line under it.
fn words(state: &State, key: &str) -> (String, String) {
    match state {
        State::Downloading { done, total } => (
            "Getting ready, one time only".into(),
            format!(
                "Downloading the speech model: {} of {} MB. After this Larynx works offline, and what you say never leaves this PC.",
                mb(*done),
                mb(*total)
            ),
        ),
        State::Loading => ("Almost ready".into(), "Loading the speech model. A few seconds.".into()),
        State::Ready => (format!("Ready. Hold {key} and talk."), "Try it in the box below, or in any app.".into()),
        State::Failed(why) => ("Something went wrong".into(), why.clone()),
    }
}

/// How it works, in three steps.
fn steps(key: &str) -> [String; 3] {
    [
        "Click where you want the words to go, in any app.".into(),
        format!("Hold {key} while you talk."),
        "Let go. Your words appear, with the ums taken out.".into(),
    ]
}

fn foot(key: &str) -> String {
    format!(
        "Larynx keeps running in the tray, by the clock (click ^ if you don't see its icon), so you can close this window. No {key} key? Right-click the icon and pick another Talk key."
    )
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// The Larynx mark, as on the Mac's icon (packaging/Larynx.icns): a dark rounded square with four white waveform
/// bars and a blue text cursor, with a soft blue glow under it. Drawn at `(x, y)`, `size` across.
unsafe fn mark(t: &ID2D1RenderTarget, x: f32, y: f32, size: f32) {
    let brush = |c| unsafe { t.CreateSolidColorBrush(&c, None).ok() };
    let (br, bg, bb) = BLUE;
    let at = |fx: f32, fy: f32| (x + fx * size, y + fy * size);
    unsafe {
        for (grow, alpha) in [(9.0, 0.06), (5.0, 0.10), (2.0, 0.16)] {
            if let Some(glow) = brush(rgba(br, bg, bb, alpha)) {
                let e = px(grow);
                t.FillRoundedRectangle(&round(rect(x - e, y - e, x + size + e, y + size + e), size * 0.23 + e), &glow);
            }
        }
        let tile = round(rect(x, y, x + size, y + size), size * 0.23);
        if let Some(navy) = brush(rgba(0.10, 0.11, 0.17, 1.0)) {
            t.FillRoundedRectangle(&tile, &navy);
        }
        // Lighter towards the top, as on the icon.
        if let Some(lift) = brush(rgba(0.20, 0.22, 0.33, 0.55)) {
            t.FillRoundedRectangle(&round(rect(x, y, x + size, y + size * 0.62), size * 0.23), &lift);
        }
        if let Some(rim) = brush(rgba(1.0, 1.0, 1.0, 0.14)) {
            t.DrawRoundedRectangle(&round(rect(x + 0.5, y + 0.5, x + size - 0.5, y + size - 0.5), size * 0.23), &rim, 1.0, None::<&ID2D1StrokeStyle>);
        }
        if let Some(white) = brush(rgba(0.95, 0.96, 1.0, 1.0)) {
            let bw = size * 0.066;
            for (cx, h) in [(0.193, 0.19), (0.33, 0.354), (0.462, 0.5), (0.594, 0.30)] {
                let (bx, by) = at(cx, 0.49);
                let half = h * size / 2.0;
                t.FillRoundedRectangle(&round(rect(bx - bw / 2.0, by - half, bx + bw / 2.0, by + half), bw / 2.0), &white);
            }
        }
        if let Some(beam) = brush(rgba(br, bg, bb, 1.0)) {
            let (cx, top) = at(0.76, 0.236);
            let (_, bottom) = at(0.76, 0.774);
            let (stem, serif) = (size * 0.042, size * 0.075);
            t.FillRoundedRectangle(&round(rect(cx - stem / 2.0, top, cx + stem / 2.0, bottom), stem / 2.0), &beam);
            for yy in [top, bottom - stem] {
                t.FillRoundedRectangle(&round(rect(cx - serif, yy, cx + serif, yy + stem), stem / 2.0), &beam);
            }
        }
    }
}

unsafe fn paint(t: &ID2D1RenderTarget, text: &glass::Text, i: &Inner, w: f32, h: f32) {
    let brush = |c| unsafe { t.CreateSolidColorBrush(&c, None).ok() };
    let (Some(tint), Some(ink), Some(quiet), Some(shine)) =
        (brush(palette::tint(i.look.glass)), brush(palette::text()), brush(palette::quiet()), brush(palette::shine()))
    else {
        return;
    };
    let draw = |s: &str, size: f32, bold: bool, wrap: bool, r: windows::Win32::Graphics::Direct2D::Common::D2D_RECT_F, b: &windows::Win32::Graphics::Direct2D::ID2D1SolidColorBrush| {
        let weight = if bold { DWRITE_FONT_WEIGHT_SEMI_BOLD } else { DWRITE_FONT_WEIGHT_NORMAL };
        if let Some(f) = text.format(px(size), weight, wrap, false) {
            unsafe { t.DrawText(&wide(s), &f, &r, b, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL) };
        }
    };
    let hero = px(HERO);
    unsafe {
        // The glass: the tint, and light catching the top edge of the sheet below.
        t.FillRectangle(&rect(0.0, 0.0, w, hero), &tint);
        mark(t, px(PAD), px(30.0), px(54.0));
        draw("Larynx", 28.0, true, false, rect(px(100.0), px(28.0), w - px(PAD), px(64.0)), &ink);
        draw("Talk instead of type. Everything stays on this PC.", 14.0, false, false, rect(px(100.0), px(64.0), w - px(PAD), px(86.0)), &quiet);

        let (heading, detail) = words(&i.state, &i.key);
        let dot = match &i.state {
            State::Ready => GREEN,
            State::Failed(_) => (0.96, 0.33, 0.33),
            _ => BLUE,
        };
        if let Some(d) = brush(rgba(dot.0, dot.1, dot.2, 1.0)) {
            let (x, y, s) = (px(PAD), px(124.0), px(10.0));
            if let Some(glow) = brush(rgba(dot.0, dot.1, dot.2, 0.25)) {
                let g = px(4.0);
                t.FillRoundedRectangle(&round(rect(x - g, y - g, x + s + g, y + s + g), s / 2.0 + g), &glow);
            }
            t.FillRoundedRectangle(&round(rect(x, y, x + s, y + s), s / 2.0), &d);
        }
        draw(&heading, 21.0, true, false, rect(px(PAD + 22.0), px(112.0), w - px(PAD), px(146.0)), &ink);
        let detail_bottom = if matches!(i.state, State::Downloading { .. }) { 204.0 } else { HERO - 8.0 };
        draw(&detail, 15.0, false, true, rect(px(PAD), px(154.0), w - px(PAD), px(detail_bottom)), &quiet);

        if let State::Downloading { done, total } = &i.state {
            let frac = if *total > 0 { (*done as f64 / *total as f64).clamp(0.0, 1.0) as f32 } else { 0.0 };
            let (x0, x1, y, bh) = (px(PAD), w - px(PAD), px(212.0), px(8.0));
            if let Some(track) = brush(rgba(1.0, 1.0, 1.0, 0.12)) {
                t.FillRoundedRectangle(&round(rect(x0, y, x1, y + bh), bh / 2.0), &track);
            }
            let fill_to = x0 + (x1 - x0) * frac;
            if fill_to > x0 + 1.0 {
                let (r, g, b) = BLUE;
                if let Some(glow) = brush(rgba(r, g, b, 0.28)) {
                    let e = px(3.0);
                    t.FillRoundedRectangle(&round(rect(x0 - e, y - e, fill_to.max(x0 + bh) + e, y + bh + e), bh / 2.0 + e), &glow);
                }
                if let Some(fill) = brush(rgba(r, g, b, 1.0)) {
                    t.FillRoundedRectangle(&round(rect(x0, y, fill_to.max(x0 + bh), y + bh), bh / 2.0), &fill);
                }
                if let Some(lit) = brush(rgba(1.0, 1.0, 1.0, 0.25)) {
                    t.FillRoundedRectangle(&round(rect(x0 + px(2.0), y + px(1.0), (fill_to - px(2.0)).max(x0 + bh), y + bh * 0.45), bh / 4.0), &lit);
                }
            }
        }

        // The sheet: solid, so the text box in it draws properly.
        if let Some(sheet) = brush(rgba(SHEET.0, SHEET.1, SHEET.2, 1.0)) {
            t.FillRectangle(&rect(0.0, hero, w, h), &sheet);
        }
        t.FillRectangle(&rect(0.0, hero, w, hero + px(1.0).max(1.0)), &shine);

        draw("HOW IT WORKS", 12.0, true, false, rect(px(PAD), px(264.0), w - px(PAD), px(282.0)), &quiet);
        let disc = brush(rgba(1.0, 1.0, 1.0, 0.09));
        let rim = brush(rgba(1.0, 1.0, 1.0, 0.16));
        for (n, line) in steps(&i.key).iter().enumerate() {
            let y = px(292.0 + n as f32 * 34.0);
            let d = px(24.0);
            if let (Some(disc), Some(rim)) = (&disc, &rim) {
                let shape = round(rect(px(PAD), y, px(PAD) + d, y + d), d / 2.0);
                t.FillRoundedRectangle(&shape, disc);
                t.DrawRoundedRectangle(&shape, rim, 1.0, None::<&ID2D1StrokeStyle>);
            }
            if let Some(f) = text.format(px(13.0), DWRITE_FONT_WEIGHT_SEMI_BOLD, false, true) {
                t.DrawText(&wide(&(n + 1).to_string()), &f, &rect(px(PAD), y, px(PAD) + d, y + d), &ink, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
            }
            draw(line, 15.0, false, false, rect(px(PAD + 36.0), y, w - px(PAD), y + d), &ink);
        }

        draw("TRY IT HERE", 12.0, true, false, rect(px(PAD), px(404.0), w - px(PAD), px(422.0)), &quiet);
        let (l, top, r, b) = FIELD;
        let field = round(rect(px(l), px(top), w - px(W - r), px(b)), px(10.0));
        if let Some(fill) = brush(rgba(FIELD_RGB.0, FIELD_RGB.1, FIELD_RGB.2, 1.0)) {
            t.FillRoundedRectangle(&field, &fill);
        }
        let ready = i.state == State::Ready;
        // A blue rim invites typing once it works; until then a quiet one, and a note in the box.
        let edge = if ready { rgba(BLUE.0, BLUE.1, BLUE.2, 0.9) } else { rgba(1.0, 1.0, 1.0, 0.14) };
        if let Some(edge) = brush(edge) {
            t.DrawRoundedRectangle(&field, &edge, if ready { px(1.5) } else { 1.0 }, None::<&ID2D1StrokeStyle>);
        }
        if !ready {
            let note = match &i.state {
                State::Failed(_) => "Not available until the speech model works.".to_string(),
                _ => "You can try it here as soon as Larynx is ready.".to_string(),
            };
            draw(&note, 15.0, false, true, rect(px(l + 18.0), px(top + 14.0), w - px(W - r) - px(18.0), px(b - 10.0)), &quiet);
        }

        draw(&foot(&i.key), 13.0, false, true, rect(px(PAD), px(548.0), w - px(PAD), h - px(10.0)), &quiet);
    }
}

unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_ERASEBKGND => LRESULT(1),
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let dc = unsafe { BeginPaint(hwnd, &mut ps) };
            let mut rc = RECT::default();
            let _ = unsafe { GetClientRect(hwnd, &mut rc) };
            WELCOME.with(|w| {
                if let Ok(w) = w.try_borrow() {
                    if let Some(i) = w.as_ref().filter(|i| i.hwnd == hwnd) {
                        glass::paint(dc, rc, |t, text| unsafe { paint(t, text, i, rc.right as f32, rc.bottom as f32) });
                    }
                }
            });
            unsafe {
                let _ = EndPaint(hwnd, &ps);
            }
            LRESULT(0)
        }
        // Windows draws an inactive window's Acrylic as a flat colour; keep the glass while another window is used.
        WM_NCACTIVATE => unsafe { DefWindowProcW(hwnd, msg, WPARAM(1), lparam) },
        WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC => {
            // The practice box: light text on the box's dark fill.
            let dc = HDC(wparam.0 as *mut _);
            unsafe {
                SetTextColor(dc, FIELD_INK);
                SetBkColor(dc, FIELD_GDI);
            }
            let b = FIELD_BRUSH.with(|b| {
                if b.get() == 0 {
                    b.set(unsafe { CreateSolidBrush(FIELD_GDI) }.0 as isize);
                }
                b.get()
            });
            LRESULT(b)
        }
        WM_DESTROY => {
            // Taken out before it is dropped, so nothing else can borrow it mid-drop.
            let gone = WELCOME.with(|w| w.borrow_mut().take());
            if let Some(i) = gone {
                unsafe {
                    let _ = DeleteObject(HGDIOBJ(i.body_font.0));
                    let _ = DestroyIcon(i.icon_big);
                    let _ = DestroyIcon(i.icon_small);
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
        let (h, b) = words(&State::Downloading { done: 312_400_000, total: 670_619_803 }, "Right Ctrl");
        assert!(h.contains("one time only"));
        assert!(b.contains("312 of 671 MB"), "{b}");
        let (h, _) = words(&State::Ready, "Right Ctrl");
        assert_eq!(h, "Ready. Hold Right Ctrl and talk.");
        assert_eq!(steps("Right Alt")[1], "Hold Right Alt while you talk.");
        assert!(foot("Right Ctrl").contains("No Right Ctrl key?"));
        let (h, b) = words(&State::Failed("Couldn't download the speech model.".into()), "Right Ctrl");
        assert_eq!(h, "Something went wrong");
        assert!(b.starts_with("Couldn't download"));
    }
}
