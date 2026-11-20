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
use windows::core::{w, BOOL, PCWSTR};
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
pub(super) fn screenshot(path: &Path) -> Result<(), String> {
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

pub(super) struct Kill(pub(super) Vec<Child>);
impl Drop for Kill {
    fn drop(&mut self) {
        for c in &mut self.0 {
            let _ = c.kill();
        }
    }
}

pub(super) fn wait_for(seconds: f64, mut f: impl FnMut() -> bool) -> Option<Duration> {
    let start = Instant::now();
    while start.elapsed().as_secs_f64() < seconds {
        if f() {
            return Some(start.elapsed());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    None
}

pub(super) fn log_events(path: &Path) -> Vec<serde_json::Value> {
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

/// Clicks the panel's button with this label with the real mouse (SendInput), as a person would.
pub(super) fn click_panel_button(label: &str) -> Result<(), String> {
    unsafe {
        let panel = FindWindowW(w!("LarynxMeetingPanel"), None).map_err(|_| "the meeting panel is not there".to_string())?;
        let title: Vec<u16> = label.encode_utf16().chain(std::iter::once(0)).collect();
        let button = FindWindowExW(Some(panel), None, w!("BUTTON"), PCWSTR(title.as_ptr()))
            .map_err(|_| format!("no {label:?} button on the meeting panel"))?;
        if !IsWindowVisible(button).as_bool() {
            return Err(format!("the {label:?} button is hidden"));
        }
        let mut r = RECT::default();
        GetWindowRect(button, &mut r).map_err(|e| e.to_string())?;
        SetCursorPos((r.left + r.right) / 2, (r.top + r.bottom) / 2).map_err(|e| e.to_string())?;
        std::thread::sleep(Duration::from_millis(150));
        let press = |flags| INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 { mi: MOUSEINPUT { dx: 0, dy: 0, mouseData: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
        };
        SendInput(&[press(MOUSEEVENTF_LEFTDOWN), press(MOUSEEVENTF_LEFTUP)], std::mem::size_of::<INPUT>() as i32);
    }
    Ok(())
}

pub(super) fn post_to_app(command: usize) -> Result<(), String> {
    unsafe {
        let app = FindWindowW(w!("LarynxApp"), None).map_err(|_| "the app's window is not there".to_string())?;
        PostMessageW(Some(app), WM_COMMAND, windows::Win32::Foundation::WPARAM(command), LPARAM(0)).map_err(|e| e.to_string())
    }
}

/// `larynx e2e-meeting`: meeting mode as a person uses it, on the real desktop. The microphone track has the call
/// mixed in (a call on speakers, no headphones) and the call's audio comes from a file (`--feed-call`). It starts a
/// meeting from the app, clicks Mute me during one of "You"'s lines and Unmute after it, clicks Stop, and waits for
/// the notes, written through a stand-in for Claude Code (`fake-claude.exe`). Then it starts another meeting, kills
/// the app partway, starts it again, and waits for the cut-off meeting to be finished. Results go to --out for
/// ci/check-meeting-app.py. For CI only: it drives the real desktop.
pub fn run_meeting(args: &Args) -> Result<(), String> {
    let app = args.flag("app").map(str::to_string).unwrap_or_else(|| std::env::current_exe().unwrap().to_string_lossy().into_owned());
    let dir = Path::new(args.flag("dir").unwrap_or("meeting"));
    let out_dir = Path::new(args.flag("out").unwrap_or("e2e-meeting"));
    let claude = args.flag("claude").ok_or("--claude <fake-claude.exe> is required")?;
    let script_path = args.flag("mode").unwrap_or("tests/meetings/client-call.json");
    std::fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;
    let out_abs = std::fs::canonicalize(out_dir).map_err(|e| e.to_string())?;
    let data = out_abs.join("data");
    let _ = std::fs::remove_dir_all(&data);

    // What the microphone hears of "You" and of the call from the speakers, in this room (room.rs): `clean` (the
    // default), `bad` (a hard room and a cheap laptop microphone) or `headset` (a Bluetooth headset's microphone).
    let room_name = args.flag("room").unwrap_or("clean");
    let room = crate::room::Room::parse(room_name).ok_or(format!("--room {room_name}: use clean, bad or headset"))?;
    let you = wav::read(&dir.join("you.wav"))?;
    let call = wav::read(&dir.join("call.wav"))?;
    let mic = crate::room::mic(&you, &call, room);
    let mic_path = out_abs.join("mic.wav");
    wav::write(&mic_path, &mic).map_err(|e| e.to_string())?;
    let seconds = mic.len() as f64 / wav::RATE as f64;

    // When each line is spoken (the layout make-meeting.py uses: each line, then 0.5 s), and the line to mute: the
    // first of "You"'s lines with "permit" in it.
    let script: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(script_path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let lines = script["lines"].as_array().ok_or("no lines in the script")?;
    let mut t = 0.0;
    let mut times = Vec::new();
    for i in 0..lines.len() {
        let n = wav::read(&dir.join("lines").join(format!("{i:03}.wav")))?.len() as f64 / wav::RATE as f64;
        times.push((t, t + n));
        t += n + 0.5;
    }
    let muted_line = lines
        .iter()
        .position(|l| l[0] == "You" && l[1].as_str().unwrap_or("").contains("permit"))
        .ok_or("no line of You's with 'permit' to mute")?;
    let (mute_at, unmute_at) = (times[muted_line].0 - 0.35, times[muted_line].1 + 0.35);

    let start_app = |log: &Path| -> Result<Child, String> {
        let mut cmd = Command::new(&app);
        cmd.args(["run", "--feed"]).arg(&mic_path).arg("--feed-call").arg(dir.join("call.wav")).arg("--log").arg(log);
        for flag in ["model", "provider", "threads"] {
            if let Some(v) = args.flag(flag) {
                cmd.args([format!("--{flag}").as_str(), v]);
            }
        }
        // `--dpi 144`: the app draws as if the screen were scaled to 150% (LARYNX_TEST_DPI), for the screenshots.
        if let Some(d) = args.flag("dpi") {
            cmd.env("LARYNX_TEST_DPI", d);
        }
        cmd.env("LARYNX_DATA_DIR", &data)
            .env("LARYNX_CLAUDE_CODE", claude)
            .env("FAKE_CLAUDE_OUT", out_abs.join("claude-code-call.json"))
            // Must not reach Claude Code: with a key there, Claude Code bills the key instead of the plan.
            .env("ANTHROPIC_API_KEY", "ci-key-that-must-not-reach-claude-code");
        cmd.spawn().map_err(|e| format!("{app}: {e}"))
    };
    let wait_ready = |log: &Path| -> Result<(), String> {
        wait_for(300.0, || log_events(log).iter().any(|e| e["event"] == "ready" || e["event"] == "error"));
        match log_events(log).into_iter().find(|e| e["event"] == "ready" || e["event"] == "error") {
            Some(e) if e["event"] == "ready" => Ok(()),
            Some(e) => Err(format!("the app could not start: {e}")),
            None => Err("the app never became ready".into()),
        }
    };
    let count = |log: &Path, event: &str| log_events(log).iter().filter(|e| e["event"] == event).count();

    let mut failures: Vec<String> = Vec::new();
    let mut report = serde_json::Map::new();
    report.insert("audio_seconds".into(), seconds.into());
    report.insert("muted_line".into(), muted_line.into());
    report.insert("mute_window".into(), serde_json::json!([mute_at, unmute_at]));
    let mut children = Kill(Vec::new());

    // 1. A whole meeting: start, Mute me, Unmute, Stop, notes.
    let log = out_abs.join("app.jsonl");
    let _ = std::fs::remove_file(&log);
    children.0.push(start_app(&log)?);
    wait_ready(&log)?;
    post_to_app(super::tray::ID_MEETING)?;
    wait_for(10.0, || count(&log, "meeting_start") >= 1).ok_or("the meeting never started")?;
    let t0 = Instant::now();
    let until = |s: f64| {
        if let Some(w) = Duration::from_secs_f64(s.max(0.0)).checked_sub(t0.elapsed()) {
            std::thread::sleep(w);
        }
    };
    until(mute_at);
    if let Err(e) = click_panel_button("Mute me") {
        failures.push(format!("mute: {e}"));
    }
    std::thread::sleep(Duration::from_millis(600));
    let _ = screenshot(&out_abs.join("panel-muted.bmp"));
    report.insert("mute_logged".into(), (count(&log, "meeting_mute") >= 1).into());
    until(unmute_at);
    if let Err(e) = click_panel_button("Unmute") {
        failures.push(format!("unmute: {e}"));
    }
    until(seconds + 1.5);
    if let Err(e) = click_panel_button("Stop") {
        failures.push(format!("stop: {e}"));
    }
    let done = wait_for(900.0, || count(&log, "meeting_done") >= 1);
    report.insert("stop_to_notes_s".into(), done.map(|d| d.as_secs_f64()).into());
    if done.is_none() {
        failures.push("the meeting was never finished after Stop".into());
    }
    let first_id = log_events(&log).iter().find(|e| e["event"] == "meeting_start").and_then(|e| e["id"].as_str().map(String::from));
    report.insert("first_id".into(), first_id.clone().into());

    // 2. A meeting cut off: start, kill the app partway, start it again; it must finish the meeting by itself.
    // (`--quick` stops after the first meeting, for the runs in other rooms.)
    let log2 = out_abs.join("app-after-restart.jsonl");
    let _ = std::fs::remove_file(&log2);
    report.insert("room".into(), room_name.into());
    if args.flag("quick").is_some() {
        drop(children);
        return finish_report(report, failures, &[("app_log", &log)], &out_abs);
    }
    std::thread::sleep(Duration::from_secs(2));
    post_to_app(super::tray::ID_MEETING)?;
    if wait_for(60.0, || count(&log, "meeting_start") >= 2).is_none() {
        failures.push("the second meeting never started".into());
    }
    std::thread::sleep(Duration::from_secs(20));
    let second_id = log_events(&log).iter().filter(|e| e["event"] == "meeting_start").nth(1).and_then(|e| e["id"].as_str().map(String::from));
    report.insert("cut_off_id".into(), second_id.clone().into());
    for c in &mut children.0 {
        let _ = c.kill();
        let _ = c.wait();
    }
    children.0.clear();
    children.0.push(start_app(&log2)?);
    if let Err(e) = wait_ready(&log2) {
        failures.push(format!("after the restart: {e}"));
    }
    let recovered = if second_id.is_some() { wait_for(900.0, || count(&log2, "meeting_done") >= 1) } else { None };
    report.insert("recovered_after_restart_s".into(), recovered.map(|d| d.as_secs_f64()).into());
    if recovered.is_none() {
        failures.push("the cut-off meeting was never finished after the restart".into());
    }
    drop(children);
    finish_report(report, failures, &[("app_log", &log), ("app_log_after_restart", &log2)], &out_abs)
}

fn finish_report(mut report: serde_json::Map<String, serde_json::Value>, failures: Vec<String>, logs: &[(&str, &Path)], out_abs: &Path) -> Result<(), String> {
    for (key, path) in logs {
        report.insert(key.to_string(), log_events(path).into_iter().filter(|e| e["event"] != "key_down").collect::<Vec<_>>().into());
    }
    report.insert("failures".into(), failures.clone().into());
    let json = serde_json::to_string_pretty(&serde_json::Value::Object(report)).unwrap();
    println!("{json}");
    std::fs::write(out_abs.join("e2e-meeting.json"), json).map_err(|e| e.to_string())?;
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
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

unsafe extern "system" fn find_console(hwnd: HWND, lparam: LPARAM) -> BOOL {
    if focus::class_name(hwnd) == "ConsoleWindowClass" && unsafe { IsWindowVisible(hwnd).as_bool() } {
        unsafe { *(lparam.0 as *mut bool) = true };
        return false.into();
    }
    true.into()
}

/// A console window is on screen (curl started without CREATE_NO_WINDOW would show one).
fn console_visible() -> bool {
    let mut found = false;
    unsafe {
        let _ = EnumWindows(Some(find_console), LPARAM(&mut found as *mut bool as isize));
    }
    found
}

/// `larynx e2e-welcome`: the very first start, as someone new sees it. Starts the app with an empty data folder and
/// no model, and checks: the welcome window opens at once; no console window appears while the model downloads; the
/// download finishes and the window turns into the instructions with the cursor in its practice box; holding Right
/// Ctrl and talking types the cleaned words into that box; closing the window leaves Larynx running; and starting
/// Larynx again brings the window back instead of doing nothing. Screenshots of both states go to --out. CI only:
/// it drives the real desktop and downloads the model (about 670 MB).
pub fn run_welcome(args: &Args) -> Result<(), String> {
    let app = args.flag("app").map(str::to_string).unwrap_or_else(|| std::env::current_exe().unwrap().to_string_lossy().into_owned());
    let feed = args.flag("feed").ok_or("--feed <wav> is required")?;
    let split = |s: Option<&str>| -> Vec<String> { s.unwrap_or_default().split('|').map(|s| s.to_lowercase()).filter(|s| !s.is_empty()).collect() };
    let (expect, reject) = (split(args.flag("expect")), split(args.flag("reject")));
    let out_dir = Path::new(args.flag("out").unwrap_or("e2e-welcome"));
    std::fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;
    let out_abs = std::fs::canonicalize(out_dir).map_err(|e| e.to_string())?;
    let data = out_abs.join("data");
    let _ = std::fs::remove_dir_all(&data);
    let log = out_abs.join("app.jsonl");
    let _ = std::fs::remove_file(&log);
    let seconds = wav::read(Path::new(feed))?.len() as f64 / wav::RATE as f64;
    let mut failures: Vec<String> = Vec::new();
    let mut report = serde_json::Map::new();
    insert::copy_only("clipboard before dictation");

    let start = |extra: &[&str]| -> Result<Child, String> {
        let mut cmd = Command::new(&app);
        cmd.args(extra).env("LARYNX_DATA_DIR", &data);
        for flag in ["provider", "threads"] {
            if let Some(v) = args.flag(flag) {
                cmd.args([format!("--{flag}").as_str(), v]);
            }
        }
        cmd.spawn().map_err(|e| format!("{app}: {e}"))
    };
    let mut children = Kill(Vec::new());
    let launched = Instant::now();
    children.0.push(start(&["run", "--feed", feed, "--welcome", "--log", &log.to_string_lossy()])?);

    let mut welcome = HWND::default();
    let appeared = wait_for(15.0, || {
        welcome = unsafe { FindWindowW(super::welcome::CLASS, None) }.unwrap_or_default();
        !welcome.is_invalid() && unsafe { IsWindowVisible(welcome).as_bool() }
    });
    report.insert("welcome_appeared_s".into(), appeared.map(|d| d.as_secs_f64()).into());
    if appeared.is_none() {
        return Err("the welcome window never appeared on the first start".into());
    }

    // The download: watch for console windows the whole time, and take one screenshot partway.
    let mut console = false;
    let mut shot = false;
    let ready = wait_for(900.0, || {
        console |= console_visible();
        if !shot && launched.elapsed() > Duration::from_millis(800) {
            shot = true;
            let _ = screenshot(&out_abs.join("welcome-downloading.bmp"));
        }
        log_events(&log).iter().any(|e| e["event"] == "ready" || e["event"] == "error")
    });
    if console {
        failures.push("a console window appeared during the first start".into());
    }
    report.insert("console_window_seen".into(), console.into());
    report.insert("first_start_ready_s".into(), launched.elapsed().as_secs_f64().into());
    if let Some(e) = log_events(&log).iter().find(|e| e["event"] == "error") {
        let _ = screenshot(&out_abs.join("welcome-failed.bmp"));
        return Err(format!("the first start failed: {e}"));
    }
    if ready.is_none() {
        return Err("the first start never became ready".into());
    }
    let model = data.join("models").join("parakeet-tdt-0.6b-v3-onnx");
    if !crate::model_ready(&model) {
        failures.push("the model is not complete after the first start".into());
    }

    // Ready: the practice box is showing and has the keyboard.
    let edit = unsafe { FindWindowExW(Some(welcome), None, w!("EDIT"), None) }.unwrap_or_default();
    let box_ready = wait_for(5.0, || !edit.is_invalid() && unsafe { IsWindowVisible(edit).as_bool() });
    if box_ready.is_none() {
        return Err("the practice box never appeared when Larynx was ready".into());
    }
    std::thread::sleep(Duration::from_millis(500));
    let _ = screenshot(&out_abs.join("welcome-ready.bmp"));
    report.insert("welcome_in_front_when_ready".into(), (unsafe { GetForegroundWindow() } == welcome).into());

    let check = Check { notepad: welcome, edit, seconds, expect: &expect, reject: &reject, out_dir: &out_abs };
    report.insert("practice_box".into(), check.dictate("practice box", &mut failures));
    let _ = screenshot(&out_abs.join("welcome-after.bmp"));

    // The Talk key menu: picking Right Alt is used and remembered (laptops without a Right Ctrl need it).
    post_to_app(super::tray::ID_KEY + 1)?;
    let picked = wait_for(5.0, || log_events(&log).iter().any(|e| e["event"] == "talk_key" && e["key"] == "ralt"));
    let saved = std::fs::read_to_string(data.join("talk-key.txt")).unwrap_or_default();
    if picked.is_none() || saved.trim() != "ralt" {
        failures.push(format!("choosing Right Alt as the talk key didn't take (saved: {saved:?})"));
    }
    post_to_app(super::tray::ID_KEY)?; // back to Right Ctrl
    wait_for(5.0, || std::fs::read_to_string(data.join("talk-key.txt")).map(|s| s.trim() == "rctrl").unwrap_or(false));

    // Closing the window leaves Larynx running; starting it again brings the window back.
    unsafe {
        let _ = PostMessageW(Some(welcome), WM_CLOSE, windows::Win32::Foundation::WPARAM(0), LPARAM(0));
    }
    let closed = wait_for(5.0, || unsafe { FindWindowW(super::welcome::CLASS, None) }.is_err());
    if closed.is_none() {
        failures.push("the welcome window didn't close".into());
    }
    if unsafe { FindWindowW(w!("LarynxApp"), None) }.is_err() {
        failures.push("closing the welcome window quit Larynx".into());
    }
    let mut second = start(&[])?;
    let reopened = wait_for(10.0, || unsafe { FindWindowW(super::welcome::CLASS, None) }.map(|h| unsafe { IsWindowVisible(h).as_bool() }).unwrap_or(false));
    let second_quit = wait_for(10.0, || matches!(second.try_wait(), Ok(Some(_))));
    if reopened.is_none() {
        failures.push("starting Larynx again didn't bring the welcome window back".into());
    }
    if second_quit.is_none() {
        let _ = second.kill();
        failures.push("a second start of Larynx kept running".into());
    }
    report.insert("second_start_reopens_welcome".into(), reopened.is_some().into());

    let events: Vec<serde_json::Value> = log_events(&log).into_iter().filter(|e| e["event"] != "key_down").collect();
    report.insert("app_log".into(), events.into());
    report.insert("failures".into(), failures.clone().into());
    let json = serde_json::to_string_pretty(&serde_json::Value::Object(report)).unwrap();
    println!("{json}");
    std::fs::write(out_abs.join("e2e.json"), json).map_err(|e| e.to_string())?;
    drop(children);
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}

const BROWSER_TITLE: &str = "Larynx browser test";

unsafe extern "system" fn find_browser(hwnd: HWND, lparam: LPARAM) -> BOOL {
    if focus::class_name(hwnd) == "Chrome_WidgetWin_1" && unsafe { IsWindowVisible(hwnd).as_bool() } {
        if focus::window_text(hwnd).is_some_and(|t| t.starts_with(BROWSER_TITLE)) {
            unsafe { *(lparam.0 as *mut HWND) = hwnd };
            return false.into();
        }
    }
    true.into()
}

/// `larynx e2e-browser`: the same dictation as `e2e`, into a text box on a web page in Microsoft Edge, which is what
/// most people type into (webmail, Teams and Outlook are built on the same engine). The page copies the box into its
/// title as it changes, so the window's title shows what arrived. CI only: it drives the real desktop.
pub fn run_browser(args: &Args) -> Result<(), String> {
    let app = args.flag("app").map(str::to_string).unwrap_or_else(|| std::env::current_exe().unwrap().to_string_lossy().into_owned());
    let feed = args.flag("feed").ok_or("--feed <wav> is required")?;
    let split = |s: Option<&str>| -> Vec<String> { s.unwrap_or_default().split('|').map(|s| s.to_lowercase()).filter(|s| !s.is_empty()).collect() };
    let (expect, reject) = (split(args.flag("expect")), split(args.flag("reject")));
    let out_dir = Path::new(args.flag("out").unwrap_or("e2e-browser"));
    std::fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;
    let out_abs = std::fs::canonicalize(out_dir).map_err(|e| e.to_string())?;
    let log = out_abs.join("app.jsonl");
    let _ = std::fs::remove_file(&log);
    let seconds = wav::read(Path::new(feed))?.len() as f64 / wav::RATE as f64;
    let mut failures: Vec<String> = Vec::new();
    let mut report = serde_json::Map::new();
    insert::copy_only("clipboard before dictation");

    let page = out_abs.join("page.html");
    std::fs::write(
        &page,
        format!(
            "<!doctype html><meta charset=utf-8><title>{BROWSER_TITLE}</title>\
             <textarea id=t autofocus style='width:90vw;height:40vh;font:16px sans-serif' \
             oninput=\"document.title='{BROWSER_TITLE}: '+this.value\"></textarea>"
        ),
    )
    .map_err(|e| e.to_string())?;
    let edge = ["C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe", "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe"]
        .into_iter()
        .find(|p| Path::new(p).exists())
        .ok_or("Microsoft Edge is not installed")?;
    let url = format!("file:///{}", page.to_string_lossy().trim_start_matches("\\\\?\\").replace('\\', "/"));
    let mut children = Kill(Vec::new());
    children.0.push(
        Command::new(edge)
            .args(["--no-first-run", "--no-default-browser-check", "--disable-features=msEdgeSidebarV2"])
            .arg(format!("--user-data-dir={}", out_abs.join("edge-profile").display()))
            .arg(format!("--app={url}"))
            .spawn()
            .map_err(|e| format!("edge: {e}"))?,
    );
    let mut browser = HWND::default();
    wait_for(30.0, || {
        browser = HWND::default();
        unsafe {
            let _ = EnumWindows(Some(find_browser), LPARAM(&mut browser as *mut HWND as isize));
        }
        !browser.is_invalid()
    })
    .ok_or("Edge's window with the test page never appeared")?;
    std::thread::sleep(Duration::from_secs(2));

    let mut cmd = Command::new(&app);
    cmd.args(["run", "--feed", feed, "--log"]).arg(&log);
    for flag in ["model", "provider", "threads"] {
        if let Some(v) = args.flag(flag) {
            cmd.args([format!("--{flag}").as_str(), v]);
        }
    }
    children.0.push(cmd.spawn().map_err(|e| format!("{app}: {e}"))?);
    wait_for(300.0, || log_events(&log).iter().any(|e| e["event"] == "ready" || e["event"] == "error"));
    if !log_events(&log).iter().any(|e| e["event"] == "ready") {
        return Err("the app never became ready".into());
    }

    let check = Check { notepad: browser, edit: browser, seconds, expect: &expect, reject: &reject, out_dir: &out_abs };
    report.insert("first".into(), check.dictate("Edge", &mut failures));
    let _ = screenshot(&out_abs.join("browser.bmp"));
    // Edge hands the window to a process of its own, so close the window rather than rely on killing the launcher.
    unsafe {
        let _ = PostMessageW(Some(browser), WM_CLOSE, windows::Win32::Foundation::WPARAM(0), LPARAM(0));
    }
    let events: Vec<serde_json::Value> = log_events(&log).into_iter().filter(|e| e["event"] != "key_down").collect();
    report.insert("app_log".into(), events.into());
    report.insert("failures".into(), failures.clone().into());
    let json = serde_json::to_string_pretty(&serde_json::Value::Object(report)).unwrap();
    println!("{json}");
    std::fs::write(out_abs.join("e2e.json"), json).map_err(|e| e.to_string())?;
    drop(children);
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}
