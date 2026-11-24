//! Meeting mode on Windows (docs/MEETINGS.md): the microphone is "You", the call's audio (WASAPI loopback of the
//! speakers, so any call app works) is "On the call". Both go to disk as they arrive, so a crash or a closed lid
//! loses nothing. Stop transcribes both, asks Claude for the notes and opens the meeting's page.
//!
//! What the person sees is one small window that always says what is happening, in large type: "Recording · 12:04"
//! with a red dot and a Stop button, then "Writing your summary…", then the notes open by themselves.

use crate::engine::Engine;
use super::glass;
use crate::meeting::{self, Meeting};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Direct2D::{ID2D1RenderTarget, ID2D1StrokeStyle, D2D1_DRAW_TEXT_OPTIONS_CLIP};
use windows::Win32::Graphics::DirectWrite::{DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_MEASURING_MODE_NATURAL};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, ODS_FLAGS, ODS_FOCUS, ODS_NOFOCUSRECT, ODS_SELECTED};
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForSystem, GetDpiForWindow};
use windows::Win32::UI::WindowsAndMessaging::*;

const RATE: u32 = 16_000;
pub const ID_PANEL_STOP: usize = 300;
pub const ID_PANEL_MUTE: usize = 301;
/// The panel's height: room for the time, two lines of note (e.g. "Only the microphone is being recorded…") and the
/// buttons. At 170 a two-line note was cut off.
const PANEL_H: i32 = 200;
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
    /// Starts recording: `you` is the microphone buffer the dictation recorder fills. `call_feed` (tests only) plays
    /// a file as the call's audio, in real time, instead of capturing the speakers.
    pub fn start(you: Arc<Mutex<Vec<f32>>>, call_feed: Option<Arc<Vec<f32>>>) -> Result<Recording, String> {
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
                    if let Some(feed) = call_feed {
                        play_into(&feed, &call, &stop);
                        return;
                    }
                    // Speakers unplugged, or Windows switched to headphones: open the new default again every
                    // second. The spooler fills the gap with silence.
                    while !stop.load(Ordering::SeqCst) {
                        match loopback(&call, &stop, &problem) {
                            Ok(()) => break,
                            Err(e) => {
                                *problem.lock().unwrap() = Some(e);
                                std::thread::sleep(Duration::from_secs(1));
                            }
                        }
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
                    let began = Instant::now();
                    let mut written = [0usize; 2];
                    loop {
                        let done = stop.load(Ordering::SeqCst);
                        for (n, (side, buf, file)) in [("you", &you, &mut you_file), ("call", &call, &mut call_file)].into_iter().enumerate() {
                            let mut chunk = std::mem::take(&mut *buf.lock().unwrap());
                            // A side more than a second behind the clock lost its device for a while: silence for
                            // the gap, so what is said after it stays in step with the other side.
                            let due = (began.elapsed().as_secs_f64() * RATE as f64) as usize;
                            if written[n] + chunk.len() + (RATE as usize) < due {
                                let gap = due - (RATE as usize) / 4 - written[n] - chunk.len();
                                let mut padded = vec![0.0f32; gap];
                                padded.extend(chunk);
                                chunk = padded;
                            }
                            written[n] += chunk.len();
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

/// Tests: a file as the call's audio, played in real time in 20 ms pieces, then silence until Stop (as a quiet call gives).
fn play_into(feed: &[f32], out: &Arc<Mutex<Vec<f32>>>, stop: &AtomicBool) {
    let start = Instant::now();
    let mut i = 0usize;
    while !stop.load(Ordering::SeqCst) {
        if let Some(w) = Duration::from_millis(i as u64 * 20).checked_sub(start.elapsed()) {
            std::thread::sleep(w);
        }
        let piece = feed.get(i * 320..((i + 1) * 320).min(feed.len())).unwrap_or(&[]);
        let mut buf = out.lock().unwrap();
        if piece.is_empty() {
            buf.extend_from_slice(&[0.0; 320]);
        } else {
            buf.extend_from_slice(piece);
        }
        i += 1;
    }
}

/// The speakers' audio, as heard by the computer (any call app). Windows sends nothing while nothing plays, so the
/// track is padded with silence by the clock: it stays in step with the microphone.
fn loopback(out: &Arc<Mutex<Vec<f32>>>, stop: &AtomicBool, problem: &Mutex<Option<String>>) -> Result<(), String> {
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
        *problem.lock().unwrap() = None;
        let opened = crate::win::audio::default_id(&devices, eRender);
        let mut checked = Instant::now();
        let began = Instant::now();
        let mut written: u64 = 0;
        while !stop.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(10));
            if checked.elapsed() > Duration::from_secs(1) {
                checked = Instant::now();
                if crate::win::audio::default_id(&devices, eRender) != opened {
                    let _ = client.Stop();
                    return Err("the speakers changed".into());
                }
            }
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
        match meeting::write_notes_any(
            &m,
            meeting::claude_code_path().as_deref(),
            crate::credential::claude_key().as_deref(),
            crate::credential::gemini_key().as_deref(),
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

/// Opens the meeting's page in the browser, on its own thread: starting a browser can take seconds, and the app's
/// window (the panel, the tray, the next Start) must not wait for it.
pub fn open(path: &std::path::Path) {
    let p: Vec<u16> = path
        .to_string_lossy()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    std::thread::spawn(move || unsafe {
        let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_APARTMENTTHREADED);
        windows::Win32::UI::Shell::ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(p.as_ptr()),
            None,
            None,
            SW_SHOWNORMAL,
        );
    });
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Dots per inch for a window: the monitor it is on now, so a change of scaling shows without signing out (the
/// system's figure is fixed at sign-in). Without a window, the system's. `LARYNX_TEST_DPI` overrides both, so CI can
/// draw the panel at 150% and 200% on a runner fixed at 100%.
fn dpi(hwnd: Option<HWND>) -> i32 {
    if let Some(d) = std::env::var("LARYNX_TEST_DPI").ok().and_then(|v| v.parse::<i32>().ok()) {
        return d.max(96);
    }
    let d = match hwnd {
        Some(h) => unsafe { GetDpiForWindow(h) },
        None => unsafe { GetDpiForSystem() },
    };
    d.max(96) as i32
}

pub(super) fn scale(px: i32) -> i32 {
    px * dpi(None) / 96
}

fn scale_at(dpi: i32, px: i32) -> i32 {
    px * dpi / 96
}

pub(super) fn font(px: i32, weight: FONT_WEIGHT) -> HFONT {
    font_at(dpi(None), px, weight)
}

fn font_at(dpi: i32, px: i32, weight: FONT_WEIGHT) -> HFONT {
    unsafe {
        CreateFontW(
            -scale_at(dpi, px),
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
    /// The dots per inch the buttons were laid out for.
    dpi: i32,
    font: HFONT,
    /// What Windows gave it: glass or opaque, rounded or square.
    pub look: glass::Look,
}

thread_local! {
    /// What Windows gave the panel (glass or not, rounded or not), for painting.
    static PANEL_LOOK: std::cell::Cell<glass::Look> = const { std::cell::Cell::new(glass::Look { glass: false, rounded: false }) };
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
            let d = dpi(Some(hwnd));
            let look = PANEL_LOOK.with(|l| l.get());
            glass::paint(dc, rc, |t, text| unsafe { paint_panel(t, text, rc, d, look, &line, red, &small) });
            unsafe {
                let _ = EndPaint(hwnd, &ps);
            }
            LRESULT(0)
        }
        // Everything is painted over the glass in WM_PAINT; erasing with GDI would only flicker.
        WM_ERASEBKGND => LRESULT(1),
        // The panel is never the active window (it must not take the keyboard from the call), and Windows draws an
        // inactive window's Acrylic as a flat colour: its frame is always told it is active.
        WM_NCACTIVATE => unsafe { DefWindowProcW(hwnd, msg, WPARAM(1), lparam) },
        WM_DRAWITEM => {
            let item = unsafe { &*(lparam.0 as *const DRAWITEMSTRUCT) };
            let mut buf = [0u16; 32];
            let n = unsafe { GetWindowTextW(item.hwndItem, &mut buf) }.max(0) as usize;
            let label = String::from_utf16_lossy(&buf[..n]);
            let d = dpi(Some(hwnd));
            let look = PANEL_LOOK.with(|l| l.get());
            let primary = item.CtlID as usize == ID_PANEL_STOP;
            let has = |f: ODS_FLAGS| item.itemState.0 & f.0 != 0;
            let (pressed, focused) = (has(ODS_SELECTED), has(ODS_FOCUS) && !has(ODS_NOFOCUSRECT));
            let rc = item.rcItem;
            glass::paint(item.hDC, rc, |t, text| unsafe { paint_button(t, text, rc, d, look, &label, primary, pressed, focused) });
            LRESULT(1)
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
        // Moved to a monitor with other scaling, or the scaling changed: the app's next render lays it out again.
        WM_DPICHANGED => LRESULT(0),
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// The panel over its glass: the tint, the lit top edge, the red dot, the time and the note.
#[allow(clippy::too_many_arguments)]
unsafe fn paint_panel(t: &ID2D1RenderTarget, text: &glass::Text, rc: RECT, d: i32, look: glass::Look, line: &str, red: bool, small: &str) {
    use glass::{palette, rect, round};
    let s = |px: f32| px * d as f32 / 96.0;
    let (w, h) = (rc.right as f32, rc.bottom as f32);
    let brush = |c| unsafe { t.CreateSolidColorBrush(&c, None).ok() };
    let (Some(tint), Some(shine), Some(ink), Some(quiet)) =
        (brush(palette::tint(look.glass)), brush(palette::shine()), brush(palette::text()), brush(palette::quiet()))
    else {
        return;
    };
    unsafe {
        t.FillRectangle(&rect(0.0, 0.0, w, h), &tint);
        let r = if look.rounded { s(8.0) } else { 0.0 };
        if !look.rounded {
            if let Some(rim) = brush(palette::rim()) {
                t.DrawRectangle(&rect(0.5, 0.5, w - 0.5, h - 0.5), &rim, 1.0, None::<&ID2D1StrokeStyle>);
            }
        }
        // Light catching the top edge.
        t.FillRectangle(&rect(r, 1.0, w - r, 1.0 + s(1.0).max(1.0)), &shine);
        let pad = s(20.0);
        let mut x = pad;
        if red {
            let dot = s(18.0);
            let y = pad + s(9.0);
            if let (Some(glow), Some(red)) = (brush(glass::rgba(0.96, 0.29, 0.29, 0.25)), brush(palette::red())) {
                let g = s(4.0);
                t.FillRoundedRectangle(&round(rect(x - g, y - g, x + dot + g, y + dot + g), dot / 2.0 + g), &glow);
                t.FillRoundedRectangle(&round(rect(x, y, x + dot, y + dot), dot / 2.0), &red);
            }
            x += dot + s(12.0);
        }
        if let Some(f) = text.format(s(24.0), DWRITE_FONT_WEIGHT_SEMI_BOLD, false, false) {
            let words: Vec<u16> = line.encode_utf16().collect();
            t.DrawText(&words, &f, &rect(x, pad, w - pad, pad + s(36.0)), &ink, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
        }
        if !small.is_empty() {
            if let Some(f) = text.format(s(16.0), DWRITE_FONT_WEIGHT_NORMAL, true, false) {
                let words: Vec<u16> = small.encode_utf16().collect();
                t.DrawText(&words, &f, &rect(pad, pad + s(46.0), w - pad, h - s(70.0)), &quiet, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
            }
        }
    }
}

/// One of the panel's buttons, drawn over the same tint: Stop (or OK) solid and light, Mute me glassy with a rim.
#[allow(clippy::too_many_arguments)]
unsafe fn paint_button(t: &ID2D1RenderTarget, text: &glass::Text, rc: RECT, d: i32, look: glass::Look, label: &str, primary: bool, pressed: bool, focused: bool) {
    use glass::{palette, rect, rgba, round};
    let s = |px: f32| px * d as f32 / 96.0;
    let (w, h) = ((rc.right - rc.left) as f32, (rc.bottom - rc.top) as f32);
    let brush = |c| unsafe { t.CreateSolidColorBrush(&c, None).ok() };
    let (fill, ink) = match (primary, pressed) {
        (true, false) => (rgba(0.96, 0.97, 0.98, 0.94), rgba(0.07, 0.08, 0.10, 1.0)),
        (true, true) => (rgba(0.80, 0.82, 0.85, 0.94), rgba(0.07, 0.08, 0.10, 1.0)),
        (false, false) => (rgba(1.0, 1.0, 1.0, 0.12), palette::text()),
        (false, true) => (rgba(1.0, 1.0, 1.0, 0.22), palette::text()),
    };
    let (Some(tint), Some(fill), Some(ink)) = (brush(palette::tint(look.glass)), brush(fill), brush(ink)) else { return };
    unsafe {
        t.FillRectangle(&rect(0.0, 0.0, w, h), &tint);
        let r = s(8.0);
        let shape = round(rect(0.5, 0.5, w - 0.5, h - 0.5), r);
        t.FillRoundedRectangle(&shape, &fill);
        if !primary {
            if let Some(rim) = brush(rgba(1.0, 1.0, 1.0, 0.26)) {
                t.DrawRoundedRectangle(&shape, &rim, 1.0, None::<&ID2D1StrokeStyle>);
            }
        }
        if !primary {
            if let Some(shine) = brush(palette::shine()) {
                t.FillRectangle(&rect(r, 1.0, w - r, 2.0), &shine);
            }
        }
        if focused {
            if let Some(ring) = brush(rgba(0.38, 0.62, 1.0, 1.0)) {
                t.DrawRoundedRectangle(&round(rect(1.5, 1.5, w - 1.5, h - 1.5), r - 1.0), &ring, 2.0, None::<&ID2D1StrokeStyle>);
            }
        }
        if let Some(f) = text.format(s(18.0), DWRITE_FONT_WEIGHT_SEMI_BOLD, false, true) {
            let words: Vec<u16> = label.encode_utf16().collect();
            t.DrawText(&words, &f, &rect(0.0, 0.0, w, h), &ink, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
        }
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
                // No WS_BORDER: Windows 11 draws the rim, and elsewhere the panel draws its own.
                WS_POPUP | WS_CLIPCHILDREN,
                0,
                0,
                scale(420),
                scale(PANEL_H),
                None,
                None,
                Some(instance.into()),
                None,
            )
            .map_err(|e| e.to_string())?;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, owner.0 as isize);
            let look = glass::apply(hwnd);
            PANEL_LOOK.with(|l| l.set(look));
            // The buttons stay real buttons (screen readers, keyboard, the tests find them by name) but are drawn by
            // the panel (owner-drawn), since a standard button's GDI drawing can't sit on glass.
            let button = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("BUTTON"),
                w!("Stop"),
                WS_CHILD | WS_VISIBLE | WINDOW_STYLE(BS_OWNERDRAW as u32),
                scale(420) - scale(20) - scale(140),
                scale(PANEL_H) - scale(20) - scale(48),
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
                WS_CHILD | WINDOW_STYLE(BS_OWNERDRAW as u32),
                scale(420) - scale(20) - scale(140) - scale(12) - scale(130),
                scale(PANEL_H) - scale(20) - scale(48),
                scale(130),
                scale(48),
                Some(hwnd),
                Some(HMENU(ID_PANEL_MUTE as *mut _)),
                Some(instance.into()),
                None,
            )
            .map_err(|e| e.to_string())?;
            // No focus ring after a mouse click; Windows shows it again once the keyboard is used (Tab).
            const UIS_SET: usize = 1;
            const UISF_HIDEFOCUS: usize = 1;
            SendMessageW(hwnd, WM_UPDATEUISTATE, Some(WPARAM((UISF_HIDEFOCUS << 16) | UIS_SET)), Some(LPARAM(0)));
            let mut panel = Panel { hwnd, button, mute, show: Show::Hidden, dpi: 0, font: HFONT::default(), look };
            panel.layout();
            Ok(panel)
        }
    }

    /// Sizes the buttons and their font for the monitor the panel is on (again whenever its scaling changes).
    fn layout(&mut self) {
        let d = dpi(Some(self.hwnd));
        if d == self.dpi {
            return;
        }
        self.dpi = d;
        let s = |px: i32| scale_at(d, px);
        unsafe {
            let (w, h) = (s(420), s(PANEL_H));
            let _ = SetWindowPos(self.button, None, w - s(20) - s(140), h - s(20) - s(48), s(140), s(48), SWP_NOZORDER | SWP_NOACTIVATE);
            let _ = SetWindowPos(self.mute, None, w - s(20) - s(140) - s(12) - s(130), h - s(20) - s(48), s(130), s(48), SWP_NOZORDER | SWP_NOACTIVATE);
            let f = font_at(d, 18, FW_SEMIBOLD);
            for b in [self.button, self.mute] {
                SendMessageW(b, WM_SETFONT, Some(WPARAM(f.0 as usize)), Some(LPARAM(1)));
            }
            if !self.font.is_invalid() {
                let _ = DeleteObject(self.font.into());
            }
            self.font = f;
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
                    small = "Your microphone is muted. The call is still recorded.".into();
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
                        let _ = InvalidateRect(Some(b), None, false);
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
            self.layout();
            let (w, h) = (scale_at(self.dpi, 420), scale_at(self.dpi, PANEL_H));
            let _ = SetWindowPos(
                self.hwnd,
                Some(HWND_TOPMOST),
                work.right - w - scale_at(self.dpi, 16),
                work.bottom - h - scale_at(self.dpi, 16),
                w,
                h,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
            // Shown without activating; its frame (and so its Acrylic) still drawn as active.
            SendMessageW(self.hwnd, WM_NCACTIVATE, Some(WPARAM(1)), Some(LPARAM(0)));
            let _ = InvalidateRect(Some(self.hwnd), None, false);
        }
    }
}

/// Which key the key window is for.
#[derive(Clone, Copy, PartialEq)]
pub enum KeyFor {
    Claude,
    Gemini,
}

static KEY_FOR_GEMINI: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The small window for pasting a key (right-click the icon → Set Claude key / Set Gemini key).
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
                let gemini = KEY_FOR_GEMINI.load(std::sync::atomic::Ordering::SeqCst);
                let saved = if gemini { crate::credential::save_gemini(key.trim()) } else { crate::credential::save(key.trim()) };
                let (text, title) = match saved {
                    Ok(()) if key.trim().is_empty() => (
                        if gemini { w!("The Gemini key was removed.") } else { w!("The Claude key was removed.") },
                        w!("Larynx"),
                    ),
                    Ok(()) => (
                        if gemini {
                            w!("Saved. Notes for your meetings will be written by Gemini.")
                        } else {
                            w!("Saved. Notes for your meetings will be written by Claude.")
                        },
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

pub fn ask_for_key(kind: KeyFor) {
    let gemini = kind == KeyFor::Gemini;
    KEY_FOR_GEMINI.store(gemini, std::sync::atomic::Ordering::SeqCst);
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
            if gemini { w!("Larynx: Gemini key for meeting notes") } else { w!("Larynx: Claude key for meeting notes") },
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
            if gemini {
                w!("Paste the Gemini key here. Larynx keeps it in Windows Credential Manager.")
            } else {
                w!("Paste the Claude key here. Larynx keeps it in Windows Credential Manager.")
            },
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
            if gemini {
                w!("Get a free key at aistudio.google.com → Get API key.")
            } else {
                w!("A key comes from console.anthropic.com → API keys.")
            },
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
