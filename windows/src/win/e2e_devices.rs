//! `larynx e2e-meeting-devices`: meeting mode through real Windows audio devices, with no file feeds. CI installs a
//! virtual audio cable (VB-Cable): two playback devices and one microphone, wired so the microphone hears everything
//! played on either. The call plays on the default playback device, so the app records it as the call *and* the
//! microphone hears it, as in a room with no headphones. "You" plays on the other playback device, which only the
//! microphone hears.
//!
//! It starts the way the runner is set up, with Windows' privacy switch blocking microphones: the panel must say so
//! (screenshot), and once the test turns microphone access on, the recording must pick the microphone up by itself.
//! Partway through, Windows' audio service is restarted, which drops every app's audio at once (as a driver update or
//! a Bluetooth headset reconnecting does): the meeting must keep going, say so, reconnect, and stay in time.
//! (Disabling the cable device itself needs a reboot while audio is playing, so it can't stand in for an unplug.)
//!
//! For CI only: it drives the real desktop and the machine's audio devices.

use super::e2e::{click_panel_button, log_events, post_to_app, screenshot, wait_for, Kill};
use crate::{wav, Args};
use std::path::Path;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use windows::core::PCWSTR;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED};

const RATE: u32 = 16_000;

fn enumerator() -> Result<IMMDeviceEnumerator, String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(|e| e.to_string())
    }
}

fn id_of(device: &IMMDevice) -> Option<String> {
    unsafe {
        let id = device.GetId().ok()?;
        let s = id.to_string().ok();
        CoTaskMemFree(Some(id.0 as *const _));
        s
    }
}

/// The default playback device and the other active one.
fn playback_devices() -> Result<(String, String), String> {
    let devices = enumerator()?;
    unsafe {
        let default = devices.GetDefaultAudioEndpoint(eRender, eConsole).map_err(|_| "no playback device".to_string())?;
        let default = id_of(&default).ok_or("no id")?;
        let all = devices.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE).map_err(|e| e.to_string())?;
        let mut others = Vec::new();
        for i in 0..all.GetCount().map_err(|e| e.to_string())? {
            if let Some(id) = all.Item(i).ok().as_ref().and_then(id_of) {
                if id != default {
                    others.push(id);
                }
            }
        }
        let other = others.into_iter().next().ok_or("only one playback device: the virtual cable is not installed")?;
        Ok((default, other))
    }
}

/// Plays `samples` on the device with this id, by the clock that started at `t0`: if the device goes away, it is
/// opened again every 300 ms and playing goes on from where the clock is (what fell in the gap is lost, as it
/// would be for a person whose headset dropped out). Returns how many times the device was lost.
fn play(id: &str, samples: &[f32], t0: Instant, stop: &AtomicBool) -> (usize, Option<String>) {
    let mut lost = 0;
    let mut last_error = None;
    let mut pos = 0usize;
    let wide: Vec<u16> = id.encode_utf16().chain(Some(0)).collect();
    while pos < samples.len() && !stop.load(Ordering::SeqCst) {
        let clock = (t0.elapsed().as_secs_f64() * RATE as f64) as usize;
        pos = pos.max(clock.min(samples.len()));
        match play_once(&wide, samples, &mut pos, stop) {
            Ok(()) => break,
            Err(e) => {
                lost += 1;
                last_error = Some(e);
                std::thread::sleep(Duration::from_millis(300));
            }
        }
    }
    (lost, last_error)
}

/// Plays from `pos` (16 kHz mono) in the device's own format (its mix format: often 48 kHz, 2 or 16 channels, float
/// or 16-bit), converting here, so no device is refused for the format.
fn play_once(id: &[u16], samples: &[f32], pos: &mut usize, stop: &AtomicBool) -> Result<(), String> {
    unsafe {
        let e = |x: windows::core::Error| x.to_string();
        let devices = enumerator()?;
        let device = devices.GetDevice(PCWSTR(id.as_ptr())).map_err(e)?;
        let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(e)?;
        let mix = client.GetMixFormat().map_err(e)?;
        let (channels, rate, bits) = ((*mix).nChannels as usize, (*mix).nSamplesPerSec as f64, (*mix).wBitsPerSample);
        let float = (*mix).wFormatTag == 3 || ((*mix).wFormatTag == 0xFFFE && bits == 32);
        let init = client.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 2_000_000, 0, mix, None);
        CoTaskMemFree(Some(mix as *const _));
        init.map_err(|x| format!("{x} ({channels} ch, {rate} Hz, {bits} bit{})", if float { " float" } else { "" }))?;
        let size = client.GetBufferSize().map_err(e)? as usize;
        let render: IAudioRenderClient = client.GetService().map_err(e)?;
        client.Start().map_err(e)?;
        let step = RATE as f64 / rate; // source samples per device frame
        let mut src = *pos as f64;
        while (src as usize) < samples.len() && !stop.load(Ordering::SeqCst) {
            let padding = client.GetCurrentPadding().map_err(e)? as usize;
            let left = ((samples.len() as f64 - src) / step) as usize;
            let n = (size - padding).min(left);
            if n > 0 {
                let data = render.GetBuffer(n as u32).map_err(e)?;
                for f in 0..n {
                    let i = src as usize;
                    let frac = (src - i as f64) as f32;
                    let a = samples[i];
                    let b = samples.get(i + 1).copied().unwrap_or(a);
                    let v = a + (b - a) * frac;
                    for c in 0..channels {
                        if float {
                            *(data as *mut f32).add(f * channels + c) = v;
                        } else if bits == 16 {
                            *(data as *mut i16).add(f * channels + c) = (v.clamp(-1.0, 1.0) * 32767.0) as i16;
                        } else {
                            *(data as *mut i32).add(f * channels + c) = (v.clamp(-1.0, 1.0) as f64 * 2_147_483_647.0) as i32;
                        }
                    }
                    src += step;
                }
                render.ReleaseBuffer(n as u32, 0).map_err(e)?;
                *pos = src as usize;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        while client.GetCurrentPadding().map_err(e)? > 0 && !stop.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = client.Stop();
        Ok(())
    }
}

/// Runs a command, returning what it printed (for the report).
fn run(program: &str, args: &[&str]) -> String {
    match Command::new(program).args(args).output() {
        Ok(o) => format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr)).trim().replace("\r\n", " "),
        Err(e) => e.to_string(),
    }
}

/// Windows' privacy switch for microphones, for desktop apps (what Settings → Privacy & security → Microphone sets).
fn allow_microphone() -> String {
    let key = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
    [format!(r"HKLM\SOFTWARE\{}", &key[9..]), format!(r"HKCU\{key}"), format!(r"HKCU\{key}\NonPackaged")]
        .iter()
        .map(|k| run("reg", &["add", k, "/v", "Value", "/t", "REG_SZ", "/d", "Allow", "/f"]))
        .collect::<Vec<_>>()
        .join(" | ")
}

pub fn run(args: &Args) -> Result<(), String> {
    let app = args.flag("app").map(str::to_string).unwrap_or_else(|| std::env::current_exe().unwrap().to_string_lossy().into_owned());
    let dir = Path::new(args.flag("dir").unwrap_or("meeting"));
    let out_dir = Path::new(args.flag("out").unwrap_or("e2e-devices"));
    let claude = args.flag("claude").ok_or("--claude <fake-claude.exe> is required")?;
    let script_path = args.flag("mode").unwrap_or("tests/meetings/client-call.json");
    std::fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;
    let out_abs = std::fs::canonicalize(out_dir).map_err(|e| e.to_string())?;
    let data = out_abs.join("data");
    let _ = std::fs::remove_dir_all(&data);

    let you = Arc::new(wav::read(&dir.join("you.wav"))?);
    let call = Arc::new(wav::read(&dir.join("call.wav"))?);
    let seconds = you.len().max(call.len()) as f64 / RATE as f64;
    let (call_device, you_device) = playback_devices()?;

    // When each line is spoken (make-meeting.py's layout: each line, then 0.5 s).
    let script: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(script_path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let lines = script["lines"].as_array().ok_or("no lines in the script")?;
    let mut t = 0.0;
    let mut timed = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        let n = wav::read(&dir.join("lines").join(format!("{i:03}.wav")))?.len() as f64 / RATE as f64;
        timed.push(serde_json::json!({"who": l[0], "text": l[1], "start": t, "end": t + n}));
        t += n + 0.5;
    }
    // Windows' audio service restarted 40% of the way in (it takes a few seconds to come back).
    let (unplug_at, plug_at) = (seconds * 0.4, seconds * 0.4 + 6.0);

    let log = out_abs.join("app.jsonl");
    let _ = std::fs::remove_file(&log);
    let mut cmd = Command::new(&app);
    cmd.args(["run", "--log"]).arg(&log);
    for flag in ["model", "provider", "threads"] {
        if let Some(v) = args.flag(flag) {
            cmd.args([format!("--{flag}").as_str(), v]);
        }
    }
    cmd.env("LARYNX_DATA_DIR", &data)
        .env("LARYNX_CLAUDE_CODE", claude)
        .env("FAKE_CLAUDE_OUT", out_abs.join("claude-code-call.json"))
        .env("LARYNX_REPORT_DIR", &out_abs);
    let child: Child = cmd.spawn().map_err(|e| format!("{app}: {e}"))?;
    let children = Kill(vec![child]);
    wait_for(300.0, || log_events(&log).iter().any(|e| e["event"] == "ready" || e["event"] == "error"));
    match log_events(&log).into_iter().find(|e| e["event"] == "ready" || e["event"] == "error") {
        Some(e) if e["event"] == "ready" => {}
        Some(e) => return Err(format!("the app could not start: {e}")),
        None => return Err("the app never became ready".into()),
    }
    let count = |event: &str| log_events(&log).iter().filter(|e| e["event"] == event).count();

    let mut failures: Vec<String> = Vec::new();
    let mut report = serde_json::Map::new();
    report.insert("audio_seconds".into(), seconds.into());
    report.insert("lines".into(), timed.into());
    report.insert("unplugged".into(), serde_json::json!([unplug_at, plug_at]));

    let audio = |pred: &dyn Fn(&serde_json::Value) -> bool| log_events(&log).iter().any(|e| e["event"] == "meeting_audio" && pred(e));
    post_to_app(super::tray::ID_MEETING)?;
    wait_for(10.0, || count("meeting_start") >= 1).ok_or("the meeting never started")?;
    let started = Instant::now();
    // The runner blocks microphones: the panel must say so, in words that say where to fix it.
    if wait_for(10.0, || audio(&|e| e["problem"].as_str().is_some_and(|p| p.contains("Privacy")))).is_some() {
        std::thread::sleep(Duration::from_millis(600));
        let _ = screenshot(&out_abs.join("panel-mic-blocked.bmp"));
        report.insert("blocked_microphone_shown".into(), true.into());
    } else {
        failures.push("with microphones blocked by Windows, the panel didn't say so".into());
    }
    // Turn microphone access on: the recording must pick the microphone up without being restarted.
    report.insert("allow_microphone".into(), allow_microphone().into());
    let picked_up = wait_for(15.0, || audio(&|e| e["problem"].is_null()));
    report.insert("microphone_picked_up_s".into(), picked_up.map(|d| d.as_secs_f64()).into());
    if picked_up.is_none() {
        failures.push("after microphone access was turned on, the recording never picked the microphone up".into());
    }
    std::thread::sleep(Duration::from_millis(1000));
    let t0 = Instant::now();
    report.insert("playing_from_s_after_start".into(), (t0 - started).as_secs_f64().into());
    let stop = Arc::new(AtomicBool::new(false));
    let players: Vec<_> = [(call_device.clone(), call.clone()), (you_device.clone(), you.clone())]
        .into_iter()
        .map(|(id, samples)| {
            let stop = stop.clone();
            std::thread::spawn(move || play(&id, &samples, t0, &stop))
        })
        .collect();
    let until = |s: f64| {
        if let Some(w) = Duration::from_secs_f64(s.max(0.0)).checked_sub(t0.elapsed()) {
            std::thread::sleep(w);
        }
    };
    until(unplug_at);
    let before = count("meeting_audio");
    report.insert("audio_service_restart".into(), run("powershell", &["-NoProfile", "-Command", "Restart-Service Audiosrv -Force; (Get-Service Audiosrv).Status"]).into());
    if wait_for(5.0, || count("meeting_audio") > before).is_some() {
        std::thread::sleep(Duration::from_millis(400));
        let _ = screenshot(&out_abs.join("panel-unplugged.bmp"));
    }
    until(plug_at);
    until(seconds + 2.0);
    stop.store(true, Ordering::SeqCst);
    let played: Vec<(usize, Option<String>)> = players.into_iter().map(|h| h.join().unwrap_or((99, Some("panicked".into())))).collect();
    report.insert(
        "players".into(),
        serde_json::json!({"call": {"lost": played[0].0, "error": played[0].1}, "you": {"lost": played[1].0, "error": played[1].1}}),
    );
    if let Err(e) = click_panel_button("Stop") {
        failures.push(format!("stop: {e}"));
    }
    let done = wait_for(900.0, || count("meeting_done") >= 1);
    report.insert("stop_to_notes_s".into(), done.map(|d| d.as_secs_f64()).into());
    if done.is_none() {
        failures.push("the meeting was never finished after Stop".into());
    }
    // "Send a report…" after the meeting: the file must appear (check-meeting-devices.py reads it).
    post_to_app(super::tray::ID_REPORT)?;
    if wait_for(60.0, || count("report_saved") >= 1).is_none() {
        failures.push("Send a report… never saved a report".into());
    }
    let id = log_events(&log).iter().find(|e| e["event"] == "meeting_start").and_then(|e| e["id"].as_str().map(String::from));
    report.insert("meeting_id".into(), id.into());
    drop(children);

    report.insert("app_log".into(), log_events(&log).into_iter().filter(|e| e["event"] != "key_down").collect::<Vec<_>>().into());
    report.insert("failures".into(), failures.clone().into());
    let json = serde_json::to_string_pretty(&serde_json::Value::Object(report)).unwrap();
    println!("{json}");
    std::fs::write(out_abs.join("e2e-devices.json"), json).map_err(|e| e.to_string())?;
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}
