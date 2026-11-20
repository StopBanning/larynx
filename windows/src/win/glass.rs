//! The meeting panel's glass, the same recipe as Locust Glass on Windows: Windows 11's own Acrylic (the window
//! manager blurs what is behind the window, so it costs the app nothing) under a dark tint, a lit top edge and a soft
//! rim. Where Acrylic can't be had (Windows 10, Windows 11 before 22H2, high contrast) the panel is the same dark
//! colours, opaque. With Transparency effects off, or no graphics card (CI's virtual machines), Windows paints
//! Acrylic's plain stand-in colour itself, and the panel reads as a dark frosted window.
//!
//! Glass needs every pixel drawn with its alpha, which GDI can't do (it writes alpha 0, so text comes out
//! see-through), so everything on the panel, its buttons included, is drawn with Direct2D into a 32-bit buffer that
//! is copied to the window alpha and all (buffered paint).

use std::cell::{Cell, RefCell};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, RECT};
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Dwm::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::HDC;
use windows::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
use windows::Win32::UI::Accessibility::{HCF_HIGHCONTRASTON, HIGHCONTRASTW};
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::WindowsAndMessaging::{SystemParametersInfoW, SPI_GETHIGHCONTRAST, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS};

/// What the window got from Windows.
#[derive(Clone, Copy, Default, PartialEq, Debug)]
pub struct Look {
    /// Acrylic is behind the window: draw the tint translucent.
    pub glass: bool,
    /// Windows 11 rounds the corners and draws the rim; otherwise the panel draws its own square rim.
    pub rounded: bool,
}

/// Windows' build number (22000 is Windows 11, 22621 is 22H2, the first with Acrylic for apps' own windows).
pub fn build() -> u32 {
    let mut buf = [0u16; 16];
    let mut size = (buf.len() * 2) as u32;
    let ok = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            w!("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"),
            w!("CurrentBuildNumber"),
            RRF_RT_REG_SZ,
            None,
            Some(buf.as_mut_ptr() as *mut _),
            Some(&mut size),
        )
    };
    if ok.is_err() {
        return 0;
    }
    let n = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..n]).trim().parse().unwrap_or(0)
}

fn high_contrast() -> bool {
    let mut hc = HIGHCONTRASTW { cbSize: std::mem::size_of::<HIGHCONTRASTW>() as u32, ..Default::default() };
    let ok = unsafe {
        SystemParametersInfoW(SPI_GETHIGHCONTRAST, hc.cbSize, Some(&mut hc as *mut _ as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0))
    };
    ok.is_ok() && hc.dwFlags.0 & HCF_HIGHCONTRASTON.0 != 0
}

/// What to ask Windows for, from the build, high contrast and `LARYNX_TEST_GLASS` (`0` turns glass off, for the
/// opaque look's screenshot).
pub fn decide(build: u32, high_contrast: bool, test: Option<&str>) -> Look {
    let rounded = build >= 22000;
    let glass = build >= 22621 && !high_contrast && test != Some("0");
    Look { glass, rounded }
}

/// Puts the window on glass where Windows can, and says what it got.
pub fn apply(hwnd: HWND) -> Look {
    apply_margins(hwnd, MARGINS { cxLeftWidth: -1, cxRightWidth: -1, cyTopHeight: -1, cyBottomHeight: -1 })
}

/// Glass over the top `top` pixels of the window only (and its title bar), the rest a normal opaque window. For
/// windows with standard controls in them (a text box), which GDI draws without alpha and would come out
/// see-through on glass.
pub fn apply_top(hwnd: HWND, top: i32) -> Look {
    apply_margins(hwnd, MARGINS { cxLeftWidth: 0, cxRightWidth: 0, cyTopHeight: top, cyBottomHeight: 0 })
}

fn apply_margins(hwnd: HWND, margins: MARGINS) -> Look {
    let want = decide(build(), high_contrast(), std::env::var("LARYNX_TEST_GLASS").ok().as_deref());
    let mut got = Look::default();
    let set = |attr: DWMWINDOWATTRIBUTE, value: &i32| unsafe {
        DwmSetWindowAttribute(hwnd, attr, value as *const i32 as *const _, 4).is_ok()
    };
    if want.rounded {
        // Dark, so Acrylic is tinted dark under the panel's light text; round corners; a soft grey rim.
        set(DWMWA_USE_IMMERSIVE_DARK_MODE, &1);
        got.rounded = set(DWMWA_WINDOW_CORNER_PREFERENCE, &DWMWCP_ROUND.0);
        set(DWMWA_BORDER_COLOR, &(RIM.0 as i32));
    }
    if want.glass {
        // The frame over the whole window, so what the panel leaves clear shows the backdrop.
        got.glass = unsafe { DwmExtendFrameIntoClientArea(hwnd, &margins).is_ok() } && set(DWMWA_SYSTEMBACKDROP_TYPE, &DWMSBT_TRANSIENTWINDOW.0);
        if !got.glass {
            let none = MARGINS::default();
            let _ = unsafe { DwmExtendFrameIntoClientArea(hwnd, &none) };
        }
    }
    got
}

/// The rim Windows 11 draws around the panel (0x00BBGGRR): a cool light grey.
const RIM: COLORREF = COLORREF(0x0074706C);

pub fn rgba(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r, g, b, a }
}

/// The panel's colours.
pub mod palette {
    use super::*;
    /// Over Acrylic: dark enough for white text over a white page behind the panel.
    pub fn tint(glass: bool) -> D2D1_COLOR_F {
        if glass { rgba(0.07, 0.08, 0.10, 0.42) } else { rgba(0.13, 0.14, 0.16, 1.0) }
    }
    pub fn text() -> D2D1_COLOR_F {
        rgba(0.96, 0.97, 0.98, 1.0)
    }
    pub fn quiet() -> D2D1_COLOR_F {
        rgba(0.78, 0.80, 0.84, 1.0)
    }
    /// The lit top edge, as on Locust Glass's panels.
    pub fn shine() -> D2D1_COLOR_F {
        rgba(1.0, 1.0, 1.0, 0.30)
    }
    /// The panel's own rim where Windows doesn't draw one.
    pub fn rim() -> D2D1_COLOR_F {
        rgba(1.0, 1.0, 1.0, 0.22)
    }
    pub fn red() -> D2D1_COLOR_F {
        rgba(0.96, 0.29, 0.29, 1.0)
    }
}

struct Gfx {
    write: IDWriteFactory,
    target: ID2D1DCRenderTarget,
}

thread_local! {
    static GFX: RefCell<Option<Gfx>> = const { RefCell::new(None) };
    static BUFFERED: Cell<bool> = const { Cell::new(false) };
}

fn gfx() -> Option<(IDWriteFactory, ID2D1DCRenderTarget)> {
    GFX.with(|g| {
        let mut g = g.borrow_mut();
        if g.is_none() {
            unsafe {
                let factory: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None).ok()?;
                let write: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED).ok()?;
                let props = D2D1_RENDER_TARGET_PROPERTIES {
                    r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
                    pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED },
                    dpiX: 96.0,
                    dpiY: 96.0,
                    usage: D2D1_RENDER_TARGET_USAGE_NONE,
                    minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
                };
                let target = factory.CreateDCRenderTarget(&props).ok()?;
                *g = Some(Gfx { write, target });
            }
        }
        g.as_ref().map(|x| (x.write.clone(), x.target.clone()))
    })
}

/// Text in Segoe UI at `px` pixels.
pub struct Text<'a> {
    write: &'a IDWriteFactory,
}

impl Text<'_> {
    pub fn format(&self, px: f32, weight: DWRITE_FONT_WEIGHT, wrap: bool, centred: bool) -> Option<IDWriteTextFormat> {
        unsafe {
            let make = |family: PCWSTR| {
                self.write.CreateTextFormat(family, None, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, px, w!("en-us"))
            };
            let f = make(w!("Segoe UI Variable Text")).or_else(|_| make(w!("Segoe UI"))).ok()?;
            let _ = f.SetWordWrapping(if wrap { DWRITE_WORD_WRAPPING_WRAP } else { DWRITE_WORD_WRAPPING_NO_WRAP });
            if centred {
                let _ = f.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
                let _ = f.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
            } else if !wrap {
                let _ = f.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
            }
            Some(f)
        }
    }
}

/// Draws `rc` of `dc` with Direct2D, alpha kept: `draw` gets the target (pixels, cleared to clear) and fonts.
pub fn paint(dc: HDC, rc: RECT, draw: impl FnOnce(&ID2D1RenderTarget, &Text)) {
    let Some((write, target)) = gfx() else { return };
    unsafe {
        if !BUFFERED.with(|b| b.replace(true)) {
            let _ = BufferedPaintInit();
        }
        let params = BP_PAINTPARAMS { cbSize: std::mem::size_of::<BP_PAINTPARAMS>() as u32, dwFlags: BPPF_ERASE, ..Default::default() };
        let mut mem = HDC::default();
        let buffer = BeginBufferedPaint(dc, &rc, BPBF_TOPDOWNDIB, Some(&params), &mut mem);
        let into = if buffer != 0 { mem } else { dc };
        if target.BindDC(into, &rc).is_ok() {
            target.BeginDraw();
            target.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE); // ClearType needs an opaque background
            let clear = rgba(0.0, 0.0, 0.0, 0.0);
            target.Clear(Some(&clear as *const _));
            draw(&target, &Text { write: &write });
            if target.EndDraw(None, None).is_err() {
                GFX.with(|g| *g.borrow_mut() = None); // device lost: a new target on the next paint
            }
        }
        if buffer != 0 {
            let _ = EndBufferedPaint(buffer, true);
        }
    }
}

pub fn rect(left: f32, top: f32, right: f32, bottom: f32) -> D2D_RECT_F {
    D2D_RECT_F { left, top, right, bottom }
}

pub fn round(r: D2D_RECT_F, radius: f32) -> D2D1_ROUNDED_RECT {
    D2D1_ROUNDED_RECT { rect: r, radiusX: radius, radiusY: radius }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glass_only_where_windows_draws_it() {
        assert_eq!(decide(19045, false, None), Look { glass: false, rounded: false }, "Windows 10");
        assert_eq!(decide(22000, false, None), Look { glass: false, rounded: true }, "Windows 11 21H2");
        assert_eq!(decide(22621, false, None), Look { glass: true, rounded: true });
        assert_eq!(decide(26100, true, None), Look { glass: false, rounded: true }, "high contrast");
        assert_eq!(decide(26100, false, Some("0")), Look { glass: false, rounded: true }, "test switch");
        assert_eq!(decide(0, false, None), Look::default(), "unknown build");
    }
}
