//! The notification-area icon and its menu.

use windows::Win32::Foundation::{HWND, POINT};
use windows::Win32::Graphics::Gdi::{CreateBitmap, CreateDIBSection, DeleteObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HGDIOBJ};
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

pub const CALLBACK: u32 = WM_APP + 3;
pub const ID_QUIT: usize = 100;
pub const ID_COPY_LAST: usize = 101;
pub const ID_OPEN_LOGS: usize = 102;

fn copy_wide(dst: &mut [u16], s: &str) {
    let w: Vec<u16> = s.encode_utf16().take(dst.len() - 1).collect();
    dst[..w.len()].copy_from_slice(&w);
    dst[w.len()] = 0;
}

/// The Larynx mark, drawn rather than shipped: a blue disc with three white waveform bars. `busy` dims it.
pub fn make_icon(size: i32, busy: bool) -> HICON {
    unsafe {
        let header = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: size,
            biHeight: -size,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let info = BITMAPINFO { bmiHeader: header, ..Default::default() };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let Ok(color) = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0) else { return HICON::default() };
        let px = std::slice::from_raw_parts_mut(bits as *mut u32, (size * size) as usize);
        let c = size as f32 / 2.0;
        let (r, g, b) = if busy { (120u32, 130u32, 150u32) } else { (64u32, 132u32, 255u32) };
        for y in 0..size {
            for x in 0..size {
                let (fx, fy) = (x as f32 + 0.5 - c, y as f32 + 0.5 - c);
                let d = (fx * fx + fy * fy).sqrt();
                let a = ((c - d).clamp(0.0, 1.0) * 255.0) as u32; // antialiased edge
                let bar = |cx: f32, half: f32| (fx - cx).abs() < size as f32 * 0.055 && fy.abs() < half;
                let s = size as f32;
                let white = bar(-s * 0.2, s * 0.14) || bar(0.0, s * 0.26) || bar(s * 0.2, s * 0.18);
                let (pr, pg, pb) = if white { (255, 255, 255) } else { (r, g, b) };
                // Premultiplied BGRA.
                px[(y * size + x) as usize] = (a << 24) | ((pr * a / 255) << 16) | ((pg * a / 255) << 8) | (pb * a / 255);
            }
        }
        let mask = CreateBitmap(size, size, 1, 1, None);
        let icon = CreateIconIndirect(&ICONINFO { fIcon: true.into(), xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color }).unwrap_or_default();
        let _ = DeleteObject(HGDIOBJ(color.0));
        let _ = DeleteObject(HGDIOBJ(mask.0));
        icon
    }
}

pub struct Tray {
    data: NOTIFYICONDATAW,
}

impl Tray {
    pub fn add(hwnd: HWND, tip: &str) -> Tray {
        let mut data = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
            uCallbackMessage: CALLBACK,
            hIcon: make_icon(32, true),
            ..Default::default()
        };
        copy_wide(&mut data.szTip, tip);
        unsafe {
            let _ = Shell_NotifyIconW(NIM_ADD, &data);
        }
        Tray { data }
    }

    /// Explorer restarted: put the icon back.
    pub fn readd(&self) {
        unsafe {
            let _ = Shell_NotifyIconW(NIM_ADD, &self.data);
        }
    }

    pub fn set(&mut self, tip: &str, ready: bool) {
        copy_wide(&mut self.data.szTip, tip);
        self.data.hIcon = make_icon(32, !ready);
        unsafe {
            let _ = Shell_NotifyIconW(NIM_MODIFY, &self.data);
        }
    }

    pub fn menu(&self, hwnd: HWND, lines: &[String]) {
        unsafe {
            let Ok(menu) = CreatePopupMenu() else { return };
            for line in lines {
                let w: Vec<u16> = line.encode_utf16().chain(std::iter::once(0)).collect();
                let _ = AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, windows::core::PCWSTR(w.as_ptr()));
            }
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
            let _ = AppendMenuW(menu, MF_STRING, ID_COPY_LAST, windows::core::w!("Copy last dictation"));
            let _ = AppendMenuW(menu, MF_STRING, ID_OPEN_LOGS, windows::core::w!("Open Larynx folder"));
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
            let _ = AppendMenuW(menu, MF_STRING, ID_QUIT, windows::core::w!("Quit Larynx"));
            let mut p = POINT::default();
            let _ = GetCursorPos(&mut p);
            // A tray menu needs its owner in front, or it won't close when you click elsewhere. This is the one
            // place Larynx takes focus, and only because you clicked its icon.
            let _ = SetForegroundWindow(hwnd);
            let _ = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, p.x, p.y, None, hwnd, None);
            let _ = DestroyMenu(menu);
        }
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &self.data);
        }
    }
}
