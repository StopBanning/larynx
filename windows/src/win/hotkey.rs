//! The talk key: a low-level keyboard hook on its own thread. Hold the key to talk, let go to finish. The key is
//! never swallowed, so nothing else breaks; pressing any other key while holding it (Right Ctrl+C...) cancels the
//! dictation, so shortcuts keep working. Our own synthetic keys are marked and ignored.

use super::insert::OURS;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::Sender;
use std::sync::OnceLock;
use std::time::Instant;
use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Debug, Clone, Copy)]
pub enum KeyEvent {
    Down(Instant),
    Up(Instant),
    Cancel,
}

static TALK: AtomicU32 = AtomicU32::new(0xA3); // VK_RCONTROL
static HELD: AtomicBool = AtomicBool::new(false);
static OTHER: AtomicBool = AtomicBool::new(false);
static SINK: OnceLock<(Sender<KeyEvent>, Box<dyn Fn() + Send + Sync>)> = OnceLock::new();

pub fn parse_key(name: &str) -> Option<u32> {
    Some(match name.to_ascii_lowercase().as_str() {
        "rctrl" | "rightctrl" | "right-ctrl" => 0xA3,
        "ralt" | "rightalt" | "right-alt" => 0xA5,
        "rshift" => 0xA1,
        "capslock" => 0x14,
        "scrolllock" => 0x91,
        "pause" => 0x13,
        "f13" => 0x7C,
        "f14" => 0x7D,
        "f15" => 0x7E,
        "f16" => 0x7F,
        "f17" => 0x80,
        "f18" => 0x81,
        "f19" => 0x82,
        "f20" => 0x83,
        _ => return None,
    })
}

pub fn key_name(vk: u32) -> &'static str {
    match vk {
        0xA3 => "Right Ctrl",
        0xA5 => "Right Alt",
        0xA1 => "Right Shift",
        0x14 => "Caps Lock",
        0x91 => "Scroll Lock",
        0x13 => "Pause",
        0x7C..=0x83 => "F13-F20",
        _ => "the talk key",
    }
}

fn emit(e: KeyEvent) {
    if let Some((tx, wake)) = SINK.get() {
        let _ = tx.send(e);
        wake();
    }
}

/// Alt and Win tapped alone open menus or Start on release. A key Windows doesn't use, pressed just before the
/// release, stops that (the same trick other hotkey tools use).
fn mask_release() {
    let k = |up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: VIRTUAL_KEY(0xE8), wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) }, time: 0, dwExtraInfo: OURS },
        },
    };
    unsafe { SendInput(&[k(false), k(true)], std::mem::size_of::<INPUT>() as i32) };
}

unsafe extern "system" fn hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let info = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        if info.dwExtraInfo != OURS {
            let msg = wparam.0 as u32;
            let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            let up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
            let talk = TALK.load(Ordering::Relaxed);
            if info.vkCode == talk {
                if down && !HELD.swap(true, Ordering::SeqCst) {
                    OTHER.store(false, Ordering::SeqCst);
                    emit(KeyEvent::Down(Instant::now()));
                } else if up && HELD.swap(false, Ordering::SeqCst) {
                    if !OTHER.load(Ordering::SeqCst) {
                        if talk == 0xA5 {
                            mask_release();
                        }
                        emit(KeyEvent::Up(Instant::now()));
                    }
                }
            } else if down && HELD.load(Ordering::SeqCst) && !OTHER.swap(true, Ordering::SeqCst) {
                emit(KeyEvent::Cancel);
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

/// Starts the hook thread. `wake` is called after each event is queued (it posts a message to the app's window).
pub fn start(vk: u32, tx: Sender<KeyEvent>, wake: Box<dyn Fn() + Send + Sync>) -> Result<(), String> {
    TALK.store(vk, Ordering::SeqCst);
    SINK.set((tx, wake)).map_err(|_| "talk key already started".to_string())?;
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("larynx-key".into())
        .spawn(move || unsafe {
            match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook), None, 0) {
                Ok(_) => {
                    let _ = ready_tx.send(Ok(()));
                    // The hook runs on this thread's message loop. Keep the callback tiny: Windows drops a hook that
                    // takes longer than about a second.
                    let mut msg = MSG::default();
                    while GetMessageW(&mut msg, None, 0, 0).as_bool() {}
                }
                Err(e) => {
                    let _ = ready_tx.send(Err(e.to_string()));
                }
            }
        })
        .map_err(|e| e.to_string())?;
    ready_rx.recv().map_err(|e| e.to_string())?
}
