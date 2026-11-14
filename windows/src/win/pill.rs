//! The pill: a small capsule just above the text you are dictating into, with a waveform and the words as you say
//! them. It never takes focus (no-activate tool window), lets clicks through (layered + transparent), stays on top,
//! and never shows in the taskbar or Alt+Tab. Drawn with Direct2D and DirectWrite.

use std::cell::RefCell;
use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{BeginPaint, EndPaint, InvalidateRect, GetMonitorInfoW, MonitorFromPoint, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST, PAINTSTRUCT};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Clone, Debug, PartialEq)]
pub enum Mode {
    Hidden,
    Listening,
    Thinking,
    Done(String),
    Problem(String),
}

pub struct State {
    pub mode: Mode,
    pub words: String,
    pub levels: Vec<f32>,
    pub app: String,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State { mode: Mode::Hidden, words: String::new(), levels: vec![0.0; 24], app: String::new() });
    static GFX: RefCell<Option<Gfx>> = const { RefCell::new(None) };
}

struct Gfx {
    target: ID2D1HwndRenderTarget,
    text: IDWriteTextFormat,
    small: IDWriteTextFormat,
    size: (u32, u32),
}

const KEY: COLORREF = COLORREF(0x00FF00FF); // magenta: the transparent outside of the capsule
const BASE_W: f32 = 380.0;
const BASE_H: f32 = 44.0;

pub struct Pill {
    pub hwnd: HWND,
    factory: ID2D1Factory,
    write: IDWriteFactory,
}

unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            unsafe {
                BeginPaint(hwnd, &mut ps);
                render();
                let _ = EndPaint(hwnd, &ps);
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

impl Pill {
    pub fn create() -> Result<Pill, String> {
        unsafe {
            let e = |x: windows::core::Error| x.to_string();
            let instance = GetModuleHandleW(None).map_err(e)?;
            let class = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(proc),
                hInstance: instance.into(),
                lpszClassName: w!("LarynxPill"),
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                ..Default::default()
            };
            RegisterClassExW(&class);
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT,
                w!("LarynxPill"),
                w!("Larynx"),
                WS_POPUP,
                0,
                0,
                BASE_W as i32,
                BASE_H as i32,
                None,
                None,
                Some(instance.into()),
                None,
            )
            .map_err(e)?;
            SetLayeredWindowAttributes(hwnd, KEY, 242, LWA_COLORKEY | LWA_ALPHA).map_err(e)?;
            let factory: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None).map_err(e)?;
            let write: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED).map_err(e)?;
            Ok(Pill { hwnd, factory, write })
        }
    }

    fn scale(&self) -> f32 {
        unsafe { GetDpiForWindow(self.hwnd).max(96) as f32 / 96.0 }
    }

    fn ensure_gfx(&self, w: u32, h: u32) {
        GFX.with(|g| {
            let mut g = g.borrow_mut();
            if g.as_ref().is_some_and(|x| x.size == (w, h)) {
                return;
            }
            unsafe {
                let props = D2D1_RENDER_TARGET_PROPERTIES {
                    r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
                    pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_IGNORE },
                    dpiX: 96.0,
                    dpiY: 96.0,
                    usage: D2D1_RENDER_TARGET_USAGE_NONE,
                    minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
                };
                let hprops = D2D1_HWND_RENDER_TARGET_PROPERTIES {
                    hwnd: self.hwnd,
                    pixelSize: D2D_SIZE_U { width: w, height: h },
                    presentOptions: D2D1_PRESENT_OPTIONS_NONE,
                };
                let s = h as f32 / BASE_H;
                let font = |size: f32, weight: DWRITE_FONT_WEIGHT| {
                    self.write
                        .CreateTextFormat(w!("Segoe UI Variable Text"), None, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, w!("en-us"))
                        .or_else(|_| self.write.CreateTextFormat(w!("Segoe UI"), None, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, w!("en-us")))
                };
                if let (Ok(target), Ok(text), Ok(small)) = (
                    self.factory.CreateHwndRenderTarget(&props, &hprops),
                    font(15.0 * s, DWRITE_FONT_WEIGHT_NORMAL),
                    font(12.0 * s, DWRITE_FONT_WEIGHT_SEMI_BOLD),
                ) {
                    for f in [&text, &small] {
                        let _ = f.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
                        let _ = f.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
                    }
                    *g = Some(Gfx { target, text, small, size: (w, h) });
                }
            }
        });
    }

    /// Places the pill just above `anchor` (the caret or the field), or above the taskbar of the monitor the
    /// target window is on, then shows it without activating it.
    pub fn show_at(&self, anchor: Option<RECT>, window: Option<HWND>) {
        let s = self.scale();
        let (w, h) = ((BASE_W * s) as i32, (BASE_H * s) as i32);
        unsafe {
            let monitor = match (anchor, window) {
                (Some(r), _) => MonitorFromPoint(POINT { x: r.left, y: r.top }, MONITOR_DEFAULTTONEAREST),
                (None, Some(win)) => MonitorFromWindow(win, MONITOR_DEFAULTTONEAREST),
                _ => MonitorFromPoint(POINT::default(), MONITOR_DEFAULTTONEAREST),
            };
            let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            let _ = GetMonitorInfoW(monitor, &mut info);
            let work = info.rcWork;
            let (mut x, mut y) = match anchor {
                Some(r) => (r.left - (12.0 * s) as i32, r.top - h - (10.0 * s) as i32),
                None => ((work.left + work.right - w) / 2, work.bottom - h - (24.0 * s) as i32),
            };
            if y < work.top {
                // No room above: go just below the anchor.
                y = anchor.map(|r| r.bottom + (10.0 * s) as i32).unwrap_or(work.top);
            }
            x = x.clamp(work.left + 8, (work.right - w - 8).max(work.left + 8));
            y = y.clamp(work.top, (work.bottom - h).max(work.top));
            let _ = SetWindowPos(self.hwnd, Some(HWND_TOPMOST), x, y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
        self.ensure_gfx(w as u32, h as u32);
        self.repaint();
    }

    pub fn hide(&self) {
        unsafe {
            let _ = ShowWindow(self.hwnd, SW_HIDE);
        }
    }

    pub fn update(&self, f: impl FnOnce(&mut State)) {
        STATE.with(|s| f(&mut s.borrow_mut()));
        self.repaint();
    }

    pub fn repaint(&self) {
        unsafe {
            let _ = InvalidateRect(Some(self.hwnd), None, false);
        }
    }

    pub fn visible(&self) -> bool {
        unsafe { IsWindowVisible(self.hwnd).as_bool() }
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// The end of the words, so the newest ones are always visible.
fn tail(words: &str, max_chars: usize) -> String {
    let n = words.chars().count();
    if n <= max_chars {
        return words.to_string();
    }
    let cut: String = words.chars().skip(n - max_chars).collect();
    let cut = cut.split_once(' ').map(|(_, rest)| rest.to_string()).unwrap_or(cut);
    format!("\u{2026}{cut}")
}

fn render() {
    GFX.with(|g| {
        let g = g.borrow();
        let Some(gfx) = g.as_ref() else { return };
        STATE.with(|st| {
            let st = st.borrow();
            let t = &gfx.target;
            let (w, h) = (gfx.size.0 as f32, gfx.size.1 as f32);
            let s = h / BASE_H;
            let color = |r: f32, g: f32, b: f32, a: f32| D2D1_COLOR_F { r, g, b, a };
            unsafe {
                t.BeginDraw();
                let key = color(1.0, 0.0, 1.0, 1.0);
                t.Clear(Some(&key as *const D2D1_COLOR_F)); // the color key: transparent
                t.SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED); // a crisp edge, so no pink fringe against the key
                let rim = t.CreateSolidColorBrush(&color(0.36, 0.38, 0.42, 1.0), None);
                let fill = t.CreateSolidColorBrush(&color(0.11, 0.12, 0.14, 1.0), None);
                if let (Ok(rim), Ok(fill)) = (rim, fill) {
                    let r = h / 2.0;
                    t.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect: D2D_RECT_F { left: 0.0, top: 0.0, right: w, bottom: h }, radiusX: r, radiusY: r }, &rim);
                    t.FillRoundedRectangle(
                        &D2D1_ROUNDED_RECT { rect: D2D_RECT_F { left: s, top: s, right: w - s, bottom: h - s }, radiusX: r - s, radiusY: r - s },
                        &fill,
                    );
                }
                t.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
                let white = t.CreateSolidColorBrush(&color(0.96, 0.97, 0.98, 1.0), None).ok();
                let dim = t.CreateSolidColorBrush(&color(0.62, 0.65, 0.70, 1.0), None).ok();
                let blue = t.CreateSolidColorBrush(&color(0.38, 0.62, 1.0, 1.0), None).ok();
                let (Some(white), Some(dim), Some(blue)) = (white, dim, blue) else {
                    let _ = t.EndDraw(None, None);
                    return;
                };
                // Left: the waveform while listening, three dots while thinking, a mark when done.
                let left = 16.0 * s;
                let mid = h / 2.0;
                match &st.mode {
                    Mode::Listening => {
                        let bars = st.levels.len().min(14);
                        for (i, level) in st.levels.iter().rev().take(bars).rev().enumerate() {
                            let v = (level.max(1e-4).log10() + 3.2).clamp(0.0, 2.6) / 2.6; // about -64 to -12 dBFS
                            let bh = (4.0 + v * 24.0) * s;
                            let x = left + i as f32 * 4.0 * s;
                            t.FillRoundedRectangle(
                                &D2D1_ROUNDED_RECT { rect: D2D_RECT_F { left: x, top: mid - bh / 2.0, right: x + 2.4 * s, bottom: mid + bh / 2.0 }, radiusX: 1.2 * s, radiusY: 1.2 * s },
                                &blue,
                            );
                        }
                    }
                    Mode::Thinking => {
                        let phase = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0) / 180) % 3;
                        for i in 0..3 {
                            let brush = if i as u128 == phase { &blue } else { &dim };
                            let x = left + 6.0 * s + i as f32 * 12.0 * s;
                            t.FillRoundedRectangle(
                                &D2D1_ROUNDED_RECT { rect: D2D_RECT_F { left: x, top: mid - 3.0 * s, right: x + 6.0 * s, bottom: mid + 3.0 * s }, radiusX: 3.0 * s, radiusY: 3.0 * s },
                                brush,
                            );
                        }
                    }
                    Mode::Done(_) => {
                        let label = wide("\u{2713}");
                        t.DrawText(&label, &gfx.text, &D2D_RECT_F { left, top: 0.0, right: left + 40.0 * s, bottom: h }, &blue, D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
                    }
                    Mode::Problem(_) => {
                        let label = wide("!");
                        t.DrawText(&label, &gfx.text, &D2D_RECT_F { left: left + 6.0 * s, top: 0.0, right: left + 40.0 * s, bottom: h }, &blue, D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
                    }
                    Mode::Hidden => {}
                }
                let text_left = left + 64.0 * s;
                let rect = D2D_RECT_F { left: text_left, top: 0.0, right: w - 18.0 * s, bottom: h };
                let (line, brush, format) = match &st.mode {
                    Mode::Listening if st.words.is_empty() => (format!("Listening{}", if st.app.is_empty() { String::new() } else { format!(" \u{00B7} {}", st.app) }), &dim, &gfx.small),
                    Mode::Listening | Mode::Thinking => (tail(&st.words, 40), &white, &gfx.text),
                    Mode::Done(m) | Mode::Problem(m) => (tail(m, 44), &white, &gfx.small),
                    Mode::Hidden => (String::new(), &dim, &gfx.small),
                };
                let line = wide(&line);
                t.DrawText(&line, format, &rect, brush, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
                if t.EndDraw(None, None).is_err() {
                    // Device lost (driver update, sleep): rebuild on the next paint.
                }
            }
        });
    });
}

