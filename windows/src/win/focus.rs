//! Where the words are going: the window and control that has the keyboard, its app, whether it is a password
//! field, and what text it holds now (so we can tell whether a paste arrived). UI Automation first, with the
//! classic window messages as a fallback for plain Edit controls.

use windows::core::{Interface, BSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT, WPARAM};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// The window that had the keyboard when the talk key went down.
#[derive(Clone, Copy, Debug)]
pub struct Target {
    pub window: HWND,
    pub focus: HWND,
    pub thread: u32,
    pub pid: u32,
    pub caret: Option<RECT>,
}

unsafe impl Send for Target {}

pub fn current() -> Option<Target> {
    unsafe {
        let window = GetForegroundWindow();
        if window.is_invalid() {
            return None;
        }
        let mut pid = 0u32;
        let thread = GetWindowThreadProcessId(window, Some(&mut pid));
        let mut info = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
        let (focus, caret) = if GetGUIThreadInfo(thread, &mut info).is_ok() {
            let caret = (!info.hwndCaret.is_invalid()).then(|| {
                let mut r = info.rcCaret;
                let mut pts = [windows::Win32::Foundation::POINT { x: r.left, y: r.top }, windows::Win32::Foundation::POINT { x: r.right, y: r.bottom }];
                windows::Win32::Graphics::Gdi::MapWindowPoints(Some(info.hwndCaret), None, &mut pts);
                r = RECT { left: pts[0].x, top: pts[0].y, right: pts[1].x, bottom: pts[1].y };
                r
            });
            (if info.hwndFocus.is_invalid() { window } else { info.hwndFocus }, caret)
        } else {
            (window, None)
        };
        Some(Target { window, focus, thread, pid, caret })
    }
}

/// The executable's full path for a process (for picking the cleanup mode and the pill's icon).
pub fn exe_path(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(h);
        ok.then(|| String::from_utf16_lossy(&buf[..len as usize]))
    }
}

pub fn class_name(hwnd: HWND) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetClassNameW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

/// Text of a classic Edit/RichEdit control by window message, with a timeout so a hung app can't stall us.
pub fn window_text(hwnd: HWND) -> Option<String> {
    unsafe {
        let mut len = 0usize;
        if SendMessageTimeoutW(hwnd, WM_GETTEXTLENGTH, WPARAM(0), LPARAM(0), SMTO_ABORTIFHUNG, 250, Some(&mut len)).0 == 0 {
            return None;
        }
        let mut buf = vec![0u16; len + 1];
        let mut got = 0usize;
        if SendMessageTimeoutW(hwnd, WM_GETTEXT, WPARAM(buf.len()), LPARAM(buf.as_mut_ptr() as isize), SMTO_ABORTIFHUNG, 250, Some(&mut got)).0 == 0 {
            return None;
        }
        Some(String::from_utf16_lossy(&buf[..got.min(len)]))
    }
}

/// UI Automation, set up once per thread (COM, multithreaded apartment).
pub struct Uia {
    auto: IUIAutomation,
}

/// What the focused element is.
pub struct Field {
    pub element: Option<IUIAutomationElement>,
    pub password: bool,
    pub editable: Option<bool>,
    pub bounds: Option<RECT>,
    pub kind: String,
}

impl Uia {
    pub fn new() -> Option<Uia> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let auto: IUIAutomation = CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)
                .or_else(|_| CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER))
                .ok()?;
            if let Ok(a2) = auto.cast::<IUIAutomation2>() {
                // A hung or slow app must not stall a dictation.
                let _ = a2.SetConnectionTimeout(500);
                let _ = a2.SetTransactionTimeout(500);
            }
            Some(Uia { auto })
        }
    }

    pub fn focused(&self) -> Field {
        unsafe {
            let Ok(el) = self.auto.GetFocusedElement() else {
                return Field { element: None, password: false, editable: None, bounds: None, kind: "unknown".into() };
            };
            let password = el.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(false);
            let control = el.CurrentControlType().map(|c| c.0).unwrap_or(0);
            let class = el.CurrentClassName().map(|b| b.to_string()).unwrap_or_default();
            let value_pattern = el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId).ok();
            let read_only = value_pattern.as_ref().and_then(|v| v.CurrentIsReadOnly().ok()).map(|b| b.as_bool());
            let has_text = el.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId).is_ok();
            // Edit (50004) and Document (50030) take typing; so does anything with a writable value.
            let editable = if control == UIA_EditControlTypeId.0 || control == UIA_DocumentControlTypeId.0 {
                Some(read_only != Some(true))
            } else if read_only == Some(false) {
                Some(true)
            } else if has_text || value_pattern.is_some() {
                None
            } else {
                Some(false)
            };
            let bounds = el.CurrentBoundingRectangle().ok().filter(|r| r.right > r.left && r.bottom > r.top);
            Field { element: Some(el), password, editable, bounds, kind: format!("{control}:{class}") }
        }
    }

    /// The element's text: its Value, or its whole document through the Text pattern.
    pub fn text(&self, el: &IUIAutomationElement) -> Option<String> {
        unsafe {
            if let Ok(v) = el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) {
                if let Ok(s) = v.CurrentValue() {
                    return Some(s.to_string());
                }
            }
            if let Ok(t) = el.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) {
                if let Ok(range) = t.DocumentRange() {
                    if let Ok(s) = range.GetText(200_000) {
                        return Some(BSTR::to_string(&s));
                    }
                }
            }
            None
        }
    }

    pub fn same(&self, a: &IUIAutomationElement, b: &IUIAutomationElement) -> bool {
        unsafe { self.auto.CompareElements(a, b).map(|r| r.as_bool()).unwrap_or(false) }
    }
}
