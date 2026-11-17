//! Meeting mode on Windows (docs/dev/MEETING.md): the microphone is "You", the call's audio (WASAPI loopback of the
//! speakers, so any call app works) is "On the call". Both go to disk as they arrive, so a crash or a closed lid
//! loses nothing. Stop transcribes both, asks Claude for the notes and opens the meeting's page.
//!
//! What the person sees is one small window that always says what is happening, in large type: "Recording · 12:04"
//! with a red dot and a Stop button, then "Writing your summary…", then the notes open by themselves.

use crate::engine::Engine;
use crate::meeting::{self, Meeting};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::GetDpiForSystem;
use windows::Win32::UI::WindowsAndMessaging::*;

const RATE: u32 = 16_000;
pub const ID_PANEL_STOP: usize = 300;
pub const ID_PANEL_MUTE: usize = 301;
const ID_KEY_EDIT: usize = 310;
const ID_KEY_SAVE: usize = 311;

/// Minutes east of UTC on this computer now (daylight saving included).
pub fn utc_offset() -> i32 {
    use windows::Win32::System::Time::{GetTimeZoneInformation, TIME_ZONE_INFORMATION};
    let mut tz = TIME_ZONE_INFORMATION::default();
    let kind = unsafe { GetTimeZoneInformation(&mut tz) };
    let bias = tz.Bias
        + if kind == 2 {
            tz.DaylightBias
        } else {
            tz.StandardBias
        };
    -bias
}

fn spool_dir() -> PathBuf {
    meeting::folder().join("spool")
}

/// What is known about a recording before it is transcribed, kept beside the audio so an interrupted one can be
/// finished after a restart.
#[derive(serde::Serialize, serde::Deserialize, Clone)]
pub struct Started {
    pub id: String,
    pub started: f64,
    pub utc_offset: i32,
}

pub struct Recording {
    pub info: Started,
    pub began: Instant,
    stop: Arc<AtomicBool>,
    spooler: Option<std::thread::JoinHandle<()>>,
    pub call_problem: Arc<Mutex<Option<String>>>,
    /// "Mute me": the microphone side is written as silence (not skipped), so both tracks keep the same length.
    pub muted: Arc<AtomicBool>,
}

impl Recording {
    /// Starts recording: `you` is the microphone buffer the dictation recorder fills.
    pub fn start(you: Arc<Mutex<Vec<f32>>>) -> Result<Recording, String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        let info = Started {
            id: format!("meeting-{}", now as u64),
            started: now,
            utc_offset: utc_offset(),
        };
        let dir = spool_dir();
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        std::fs::write(
            dir.join(format!("{}.json", info.id)),
            serde_json::to_string(&info).unwrap(),
        )
        .map_err(|e| e.to_string())?;
        let stop = Arc::new(AtomicBool::new(false));
        let call = Arc::new(Mutex::new(Vec::<f32>::new()));
        let call_problem = Arc::new(Mutex::new(None));
        {
            let (call, stop, problem) = (call.clone(), stop.clone(), call_problem.clone());
            std::thread::Builder::new()
                .name("larynx-call-audio".into())
                .spawn(move || {
                    if let Err(e) = loopback(&call, &stop) {
                        *problem.lock().unwrap() = Some(e);
                    }
                })
                .map_err(|e| e.to_string())?;
        }
        let muted = Arc::new(AtomicBool::new(false));
        // Once a second, whatever arrived goes to the end of each track's file.
        let spooler = {
            let (stop, id, muted) = (stop.clone(), info.id.clone(), muted.clone());
            std::thread::Builder::new()
                .name("larynx-meeting-spool".into())
                .spawn(move || {
                    let open = |side: &str| {
                        std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(spool_dir().join(format!("{id}-{side}.f32")))
                            .ok()
                    };
                    let (mut you_file, mut call_file) = (open("you"), open("call"));
                    loop {
                        let done = stop.load(Ordering::SeqCst);
                        for (side, buf, file) in [("you", &you, &mut you_file), ("call", &call, &mut call_file)] {
                            let mut chunk = std::mem::take(&mut *buf.lock().unwrap());
                            if side == "you" && muted.load(Ordering::SeqCst) {
                                chunk.iter_mut().for_each(|x| *x = 0.0);
                            }
                            if let Some(f) = file.as_mut() {
                                let bytes: Vec<u8> =
                                    chunk.iter().flat_map(|x| x.to_le_bytes()).collect();
                                let _ = f.write_all(&bytes);
                            }
                        }
                        if done {
                            break;
                        }
                        std::thread::sleep(Duration::from_secs(1));
                    }
                })
                .map_err(|e| e.to_string())?
        };
        Ok(Recording {
            info,
            began: Instant::now(),
            stop,
            spooler: Some(spooler),
            call_problem,
            muted,
        })
    }

    /// Stops both tracks and waits for the last second to reach the disk.
    pub fn stop(mut self) -> Started {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.spooler.take() {
            let _ = h.join();
        }
        self.info.clone()
    }
}

/// The speakers' audio, as heard by the computer (any call app). Windows sends nothing while nothing plays, so the
/// track is padded with silence by the clock: it stays in step with the microphone.
fn loopback(out: &Arc<Mutex<Vec<f32>>>, stop: &AtomicBool) -> Result<(), String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let e = |x: windows::core::Error| x.to_string();
        let devices: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(e)?;
        let device = devices
            .GetDefaultAudioEndpoint(eRender, eConsole)
            .map_err(|_| "no speakers or headphones".to_string())?;
        let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(e)?;
        let format = WAVEFORMATEX {
            wFormatTag: 3, // IEEE float
            nChannels: 1,
            nSamplesPerSec: RATE,
            nAvgBytesPerSec: RATE * 4,
            nBlockAlign: 4,
            wBitsPerSample: 32,
            cbSize: 0,
        };
        client
            .Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_LOOPBACK
                    | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                    | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                2_000_000, // 200 ms
                0,
                &format,
                None,
            )
            .map_err(e)?;
        let cap: IAudioCaptureClient = client.GetService().map_err(e)?;
        client.Start().map_err(e)?;
        let began = Instant::now();
        let mut written: u64 = 0;
        while !stop.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(10));
            loop {
                let n = cap.GetNextPacketSize().map_err(e)?;
                if n == 0 {
                    break;
                }
                let mut data: *mut u8 = std::ptr::null_mut();
                let (mut frames, mut flags) = (0u32, 0u32);
                cap.GetBuffer(&mut data, &mut frames, &mut flags, None, None)
                    .map_err(e)?;
                let samples: Vec<f32> =
                    if flags & (AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) != 0 || data.is_null() {
                        vec![0.0; frames as usize]
                    } else {
                        std::slice::from_raw_parts(data as *const f32, frames as usize).to_vec()
                    };
                cap.ReleaseBuffer(frames).map_err(e)?;
                written += samples.len() as u64;
                out.lock().unwrap().extend_from_slice(&samples);
            }
            // Nothing playing: fill the gap up to 150 ms behind the clock (packets may still be on their way).
            let due = (began.elapsed().as_secs_f64() * RATE as f64) as u64;
            if due > written + 2_400 {
                let gap = (due - written - 2_400) as usize;
                out.lock().unwrap().extend(std::iter::repeat_n(0.0f32, gap));
                written += gap as u64;
            }
        }
        let _ = client.Stop();
        Ok(())
    }
}

fn read_track(path: &std::path::Path) -> Vec<f32> {
    std::fs::read(path)
        .map(|b| {
            b.chunks_exact(4)
                .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                .collect()
        })
        .unwrap_or_default()
}

pub struct Outcome {
    pub page: Option<PathBuf>,
    pub problem: Option<String>,
}

/// After Stop (or after a restart, for a recording that was interrupted): transcribe both tracks, write the notes,
/// save the meeting and its page, and clear the audio. The transcript is saved even when the notes can't be written.
pub fn finish(info: &Started, engine: &Arc<Mutex<Engine>>, email: &str) -> Outcome {
    let dir = spool_dir();
    let you = read_track(&dir.join(format!("{}-you.f32", info.id)));
    let call = read_track(&dir.join(format!("{}-call.f32", info.id)));
    let has_call = call.iter().any(|x| x.abs() > 0.003);
    let segments = {
        let mut engine = engine.lock().unwrap();
        crate::bench::meeting_transcript(&mut engine, &you, has_call.then_some(call.as_slice()))
    };
    let segments = match segments {
        Ok(s) => meeting::remove_echo(s),
        Err(e) => return Outcome {
            page: None,
            problem: Some(format!(
                "The recording couldn't be transcribed ({e}). It's kept and will be tried again."
            )),
        },
    };
    let duration = you.len().max(call.len()) as f64 / RATE as f64;
    let mut m = Meeting {
        id: info.id.clone(),
        started: info.started,
        duration,
        utc_offset: info.utc_offset,
        segments,
        notes: None,
    };
    let mut problem = None;
    if m.segments.is_empty() {
        problem = Some("I didn't hear anyone speak in this recording. If people were talking, check that the microphone isn't muted.".into());
    } else {
        match meeting::notes_by_claude(
            &m,
            meeting::claude_code_path().as_deref(),
            crate::credential::claude_key().as_deref(),
            &meeting::curl_post,
            &meeting::sleep_seconds,
        ) {
            Ok(n) => m.notes = Some(n),
            Err(e) => {
                problem = Some(format!(
                    "The summary couldn't be written. {e} Everything that was said is saved."
                ))
            }
        }
    }
    match meeting::save(&m, email) {
        Ok(page) => {
            for side in ["you.f32", "call.f32"] {
                let _ = std::fs::remove_file(dir.join(format!("{}-{side}", info.id)));
            }
            let _ = std::fs::remove_file(dir.join(format!("{}.json", info.id)));
            Outcome {
                page: Some(page),
                problem,
            }
        }
        Err(e) => Outcome {
            page: None,
            problem: Some(format!(
                "The meeting couldn't be saved ({e}). The recording is kept."
            )),
        },
    }
}

/// Recordings that were never finished (the app closed or crashed while recording).
pub fn interrupted() -> Vec<Started> {
    let Ok(entries) = std::fs::read_dir(spool_dir()) else {
        return vec![];
    };
    entries
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        .filter_map(|e| std::fs::read_to_string(e.path()).ok())
        .filter_map(|t| serde_json::from_str(&t).ok())
        .collect()
}

/// The newest saved meeting that has no notes yet, for "Write the summary again".
pub fn latest_without_notes() -> Option<Meeting> {
    let entries = std::fs::read_dir(meeting::folder()).ok()?;
    entries
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        .filter_map(|e| meeting::load(&e.path()).ok())
        .filter(|m| m.notes.is_none() && !m.segments.is_empty())
        .max_by(|a, b| {
            a.started
                .partial_cmp(&b.started)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
}

pub fn open(path: &std::path::Path) {
    let p: Vec<u16> = path
        .to_string_lossy()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    unsafe {
        windows::Win32::UI::Shell::ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(p.as_ptr()),
            None,
            None,
            SW_SHOWNORMAL,
        );
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn scale(px: i32) -> i32 {
    let dpi = unsafe { GetDpiForSystem() }.max(96) as i32;
    px * dpi / 96
}

fn font(px: i32, weight: FONT_WEIGHT) -> HFONT {
    unsafe {
        CreateFontW(
            -scale(px),
            0,
            0,
            0,
            weight.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            0,
            w!("Segoe UI"),
        )
    }
}

/// What the panel shows.
#[derive(Clone, PartialEq)]
pub enum Show {
    Hidden,
    Recording {
        since: Instant,
        note: Option<String>,
        muted: bool,
    },
    Working(String),
    Problem(String),
}

/// The always-on-top window in the corner: large, plain words about what is happening, and one button.
pub struct Panel {
    pub hwnd: HWND,
    button: HWND,
    mute: HWND,
    pub show: Show,
}

thread_local! {
    static PANEL_TEXT: std::cell::RefCell<(String, bool, String)> = const { std::cell::RefCell::new((String::new(), false, String::new())) };
}

unsafe extern "system" fn panel_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let dc = unsafe { BeginPaint(hwnd, &mut ps) };
            let mut rc = RECT::default();
            let _ = unsafe { GetClientRect(hwnd, &mut rc) };
            let (line, red, small) = PANEL_TEXT.with(|t| t.borrow().clone());
            unsafe {
                let bg = CreateSolidBrush(COLORREF(0x00FFFFFF));
                FillRect(dc, &rc, bg);
                let _ = DeleteObject(bg.into());
                SetBkMode(dc, TRANSPARENT);
                let pad = scale(20);
                let mut x = pad;
                if red {
                    let dot = CreateSolidBrush(COLORREF(0x002020D8)); // BGR: red
                    let old = SelectObject(dc, dot.into());
                    let d = scale(18);
                    let y = pad + scale(6);
                    let _ = Ellipse(dc, x, y, x + d, y + d);
                    SelectObject(dc, old);
                    let _ = DeleteObject(dot.into());
                    x += d + scale(12);
                }
                let big = font(24, FW_SEMIBOLD);
                let old = SelectObject(dc, big.into());
                SetTextColor(dc, COLORREF(0x00111111));
                let mut r = RECT {
                    left: x,
                    top: pad,
                    right: rc.right - pad,
                    bottom: pad + scale(36),
                };
                let mut text = wide(&line);
                let n = text.len() - 1;
                DrawTextW(dc, &mut text[..n], &mut r, DT_SINGLELINE | DT_VCENTER);
                SelectObject(dc, old);
                let _ = DeleteObject(big.into());
                if !small.is_empty() {
                    let f = font(16, FW_NORMAL);
                    let old = SelectObject(dc, f.into());
                    SetTextColor(dc, COLORREF(0x00444444));
                    let mut r = RECT {
                        left: pad,
                        top: pad + scale(44),
                        right: rc.right - pad,
                        bottom: rc.bottom - scale(70),
                    };
                    let mut text = wide(&small);
                    let n = text.len() - 1;
                    DrawTextW(dc, &mut text[..n], &mut r, DT_WORDBREAK);
                    SelectObject(dc, old);
                    let _ = DeleteObject(f.into());
                }
                let _ = EndPaint(hwnd, &ps);
            }
            LRESULT(0)
        }
        WM_COMMAND if matches!(wparam.0 & 0xFFFF, ID_PANEL_STOP | ID_PANEL_MUTE) => {
            // The app window decides what the buttons mean (Stop, or OK on a problem; Mute me / Unmute).
            let owner = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
            unsafe {
                let _ = PostMessageW(
                    Some(HWND(owner as *mut _)),
                    WM_COMMAND,
                    WPARAM(wparam.0 & 0xFFFF),
                    LPARAM(0),
                );
            }
            LRESULT(0)
        }
        WM_CLOSE => LRESULT(0), // only Stop ends a recording
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

impl Panel {
    pub fn create(owner: HWND) -> Result<Panel, String> {
        unsafe {
            let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
            let class = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(panel_proc),
                hInstance: instance.into(),
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                lpszClassName: w!("LarynxMeetingPanel"),
                ..Default::default()
            };
            RegisterClassExW(&class);
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                w!("LarynxMeetingPanel"),
                w!("Larynx meeting"),
                WS_POPUP | WS_BORDER,
                0,
                0,
                scale(420),
                scale(170),
                None,
                None,
                Some(instance.into()),
                None,
            )
            .map_err(|e| e.to_string())?;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, owner.0 as isize);
            let button = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("BUTTON"),
                w!("Stop"),
                WS_CHILD | WS_VISIBLE | WINDOW_STYLE(BS_DEFPUSHBUTTON as u32),
                scale(420) - scale(20) - scale(140),
                scale(170) - scale(20) - scale(48),
                scale(140),
                scale(48),
                Some(hwnd),
                Some(HMENU(ID_PANEL_STOP as *mut _)),
                Some(instance.into()),
                None,
            )
            .map_err(|e| e.to_string())?;
            // "Mute me", left of Stop: keeps recording the call but not the microphone (a noisy room, or the call
            // playing through the speakers).
            let mute = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("BUTTON"),
                w!("Mute me"),
                WS_CHILD | WINDOW_STYLE(BS_PUSHBUTTON as u32),
                scale(420) - scale(20) - scale(140) - scale(12) - scale(130),
                scale(170) - scale(20) - scale(48),
                scale(130),
                scale(48),
                Some(hwnd),
                Some(HMENU(ID_PANEL_MUTE as *mut _)),
                Some(instance.into()),
                None,
            )
            .map_err(|e| e.to_string())?;
            let f = font(18, FW_SEMIBOLD);
            for b in [button, mute] {
                SendMessageW(b, WM_SETFONT, Some(WPARAM(f.0 as usize)), Some(LPARAM(1)));
            }
            Ok(Panel {
                hwnd,
                button,
                mute,
                show: Show::Hidden,
            })
        }
    }

    /// Redraws for the current state; the app calls it once a second while recording.
    pub fn render(&mut self) {
        let mute_label = match &self.show {
            Show::Recording { muted, .. } => Some(if *muted { "Unmute" } else { "Mute me" }),
            _ => None,
        };
        let (line, red, small, button) = match &self.show {
            Show::Hidden => {
                unsafe {
                    let _ = ShowWindow(self.hwnd, SW_HIDE);
                }
                return;
            }
            Show::Recording { since, note, muted } => {
                let s = since.elapsed().as_secs_f64();
                let mut small = note.clone().unwrap_or_default();
                if *muted && small.is_empty() {
                    small = "Your microphone is muted. The call is still being recorded.".into();
                }
                (format!("Recording · {}", meeting::clock(s)), true, small, Some("Stop"))
            }
            Show::Working(what) => (
                "Writing your summary…".to_string(),
                false,
                what.clone(),
                None,
            ),
            Show::Problem(what) => (
                "Something needs a look".to_string(),
                false,
                what.clone(),
                Some("OK"),
            ),
        };
        PANEL_TEXT.with(|t| *t.borrow_mut() = (line, red, small));
        unsafe {
            for (b, label) in [(self.button, button), (self.mute, mute_label)] {
                match label {
                    Some(label) => {
                        let _ = SetWindowTextW(b, PCWSTR(wide(label).as_ptr()));
                        let _ = ShowWindow(b, SW_SHOW);
                    }
                    None => {
                        let _ = ShowWindow(b, SW_HIDE);
                    }
                }
            }
            // Bottom-right, above the taskbar.
            let mut work = RECT::default();
            let _ = SystemParametersInfoW(
                SPI_GETWORKAREA,
                0,
                Some(&mut work as *mut RECT as *mut _),
                SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
            );
            let (w, h) = (scale(420), scale(170));
            let _ = SetWindowPos(
                self.hwnd,
                Some(HWND_TOPMOST),
                work.right - w - scale(16),
                work.bottom - h - scale(16),
                w,
                h,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
            let _ = InvalidateRect(Some(self.hwnd), None, true);
        }
    }
}

/// The small window for pasting the Claude key (right-click the icon → Set Claude key).
unsafe extern "system" fn key_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_COMMAND if wparam.0 & 0xFFFF == ID_KEY_SAVE => {
            unsafe {
                let edit = GetDlgItem(Some(hwnd), ID_KEY_EDIT as i32).unwrap_or_default();
                let mut buf = vec![0u16; 512];
                let n = GetWindowTextW(edit, &mut buf).max(0) as usize;
                let key = String::from_utf16_lossy(&buf[..n]);
                let (text, title) = match crate::credential::save(key.trim()) {
                    Ok(()) if key.trim().is_empty() => {
                        (w!("The Claude key was removed."), w!("Larynx"))
                    }
                    Ok(()) => (
                        w!("Saved. Notes for your meetings will be written by Claude."),
                        w!("Larynx"),
                    ),
                    Err(_) => (
                        w!("The key couldn't be saved. Try again, or ask for help."),
                        w!("Larynx"),
                    ),
                };
                MessageBoxW(Some(hwnd), text, title, MB_OK | MB_ICONINFORMATION);
                let _ = DestroyWindow(hwnd);
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

pub fn ask_for_key() {
    unsafe {
        let Ok(instance) = GetModuleHandleW(None) else {
            return;
        };
        let class = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(key_proc),
            hInstance: instance.into(),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH((COLOR_WINDOW.0 + 1) as usize as *mut _),
            lpszClassName: w!("LarynxClaudeKey"),
            ..Default::default()
        };
        RegisterClassExW(&class);
        let (w, h) = (scale(520), scale(230));
        let Ok(hwnd) = CreateWindowExW(
            WS_EX_TOPMOST,
            w!("LarynxClaudeKey"),
            w!("Larynx: Claude key for meeting notes"),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
            scale(200),
            scale(200),
            w,
            h,
            None,
            None,
            Some(instance.into()),
            None,
        ) else {
            return;
        };
        let f = font(16, FW_NORMAL);
        let child = |class: PCWSTR,
                     text: PCWSTR,
                     style: WINDOW_STYLE,
                     x: i32,
                     y: i32,
                     cw: i32,
                     ch: i32,
                     id: usize,
                     ex: WINDOW_EX_STYLE| {
            let c = CreateWindowExW(
                ex,
                class,
                text,
                WS_CHILD | WS_VISIBLE | style,
                x,
                y,
                cw,
                ch,
                Some(hwnd),
                Some(HMENU(id as *mut _)),
                Some(instance.into()),
                None,
            )
            .unwrap_or_default();
            SendMessageW(c, WM_SETFONT, Some(WPARAM(f.0 as usize)), Some(LPARAM(1)));
            c
        };
        let pad = scale(20);
        child(
            w!("STATIC"),
            w!("Paste the Claude key here. Larynx keeps it in Windows Credential Manager."),
            WINDOW_STYLE(0),
            pad,
            pad,
            w - 2 * pad,
            scale(24),
            0,
            WINDOW_EX_STYLE(0),
        );
        let edit = child(
            w!("EDIT"),
            w!(""),
            WS_TABSTOP | WINDOW_STYLE((ES_PASSWORD | ES_AUTOHSCROLL) as u32),
            pad,
            pad + scale(34),
            w - 2 * pad - scale(16),
            scale(32),
            ID_KEY_EDIT,
            WS_EX_CLIENTEDGE,
        );
        child(
            w!("STATIC"),
            w!("A key comes from console.anthropic.com → API keys."),
            WINDOW_STYLE(0),
            pad,
            pad + scale(76),
            w - 2 * pad,
            scale(24),
            0,
            WINDOW_EX_STYLE(0),
        );
        child(
            w!("BUTTON"),
            w!("Save"),
            WS_TABSTOP | WINDOW_STYLE(BS_DEFPUSHBUTTON as u32),
            w - pad - scale(120) - scale(16),
            pad + scale(112),
            scale(120),
            scale(40),
            ID_KEY_SAVE,
            WINDOW_EX_STYLE(0),
        );
        let _ = windows::Win32::UI::Input::KeyboardAndMouse::SetFocus(Some(edit));
    }
}
