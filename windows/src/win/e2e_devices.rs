//! `larynx e2e-meeting-devices`: meeting mode through real Windows audio devices, with no file feeds. CI installs a
//! virtual audio cable (VB-Cable): two playback devices and one microphone, wired so the microphone hears everything
//! played on either. The call plays on the default playback device, so the app records it as the call *and* the
//! microphone hears it, as in a room with no headphones. "You" plays on the other playback device, which only the
//! microphone hears. Partway through, the cable is unplugged for a few seconds (`pnputil /disable-device`), as a
//! headset dropping out would be; the meeting must keep going, say so on the panel, and line up again afterwards.
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
fn play(id: &str, samples: &[f32], t0: Instant, stop: &AtomicBool) -> usize {
    let mut lost = 0;
    let mut pos = 0usize;
    let wide: Vec<u16> = id.encode_utf16().chain(Some(0)).collect();
    while pos < samples.len() && !stop.load(Ordering::SeqCst) {
        let clock = (t0.elapsed().as_secs_f64() * RATE as f64) as usize;
        pos = pos.max(clock.min(samples.len()));
        match play_once(&wide, samples, &mut pos, stop) {
            Ok(()) => break,
            Err(_) => {
                lost += 1;
                std::thread::sleep(Duration::from_millis(300));
            }
        }
    }
    lost
}

fn play_once(id: &[u16], samples: &[f32], pos: &mut usize, stop: &AtomicBool) -> Result<(), String> {
    unsafe {
        let e = |x: windows::core::Error| x.to_string();
        let devices = enumerator()?;
        let device = devices.GetDevice(PCWSTR(id.as_ptr())).map_err(e)?;
        let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(e)?;
        let format = WAVEFORMATEX {
            wFormatTag: 3,
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
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                2_000_000,
                0,
                &format,
                None,
            )
            .map_err(e)?;
        let size = client.GetBufferSize().map_err(e)? as usize;
        let render: IAudioRenderClient = client.GetService().map_err(e)?;
        client.Start().map_err(e)?;
        while *pos < samples.len() && !stop.load(Ordering::SeqCst) {
            let padding = client.GetCurrentPadding().map_err(e)? as usize;
            let n = (size - padding).min(samples.len() - *pos);
            if n > 0 {
                let data = render.GetBuffer(n as u32).map_err(e)?;
                std::ptr::copy_nonoverlapping(samples[*pos..].as_ptr(), data as *mut f32, n);
                render.ReleaseBuffer(n as u32, 0).map_err(e)?;
                *pos += n;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        // Let what is queued play out.
        while client.GetCurrentPadding().map_err(e)? > 0 && !stop.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = client.Stop();
        Ok(())
    }
}

fn pnputil(what: &str, device: &str) -> String {
    match Command::new("pnputil").args([what, device]).output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim().replace("\r\n", " "),
        Err(e) => e.to_string(),
    }
}

pub fn run(args: &Args) -> Result<(), String> {
    let app = args.flag("app").map(str::to_string).unwrap_or_else(|| std::env::current_exe().unwrap().to_string_lossy().into_owned());
    let dir = Path::new(args.flag("dir").unwrap_or("meeting"));
    let out_dir = Path::new(args.flag("out").unwrap_or("e2e-devices"));
    let claude = args.flag("claude").ok_or("--claude <fake-claude.exe> is required")?;
    let cable = args.flag("unplug").ok_or("--unplug <device instance id of the virtual cable> is required")?;
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
    // Unplugged for 4 s, starting 40% of the way in.
    let (unplug_at, plug_at) = (seconds * 0.4, seconds * 0.4 + 4.0);

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

    post_to_app(super::tray::ID_MEETING)?;
    wait_for(10.0, || count("meeting_start") >= 1).ok_or("the meeting never started")?;
    // The meeting is running; give the microphone and the call capture a moment to open, then play both sides.
    std::thread::sleep(Duration::from_millis(1500));
    let t0 = Instant::now();
    report.insert("playing_from_s_after_start".into(), 1.5.into());
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
    report.insert("unplug".into(), pnputil("/disable-device", cable).into());
    std::thread::sleep(Duration::from_millis(2500));
    let _ = screenshot(&out_abs.join("panel-unplugged.bmp"));
    until(plug_at);
    report.insert("plug".into(), pnputil("/enable-device", cable).into());
    until(seconds + 2.0);
    stop.store(true, Ordering::SeqCst);
    let lost: Vec<usize> = players.into_iter().map(|h| h.join().unwrap_or(99)).collect();
    report.insert("players_lost_device".into(), serde_json::json!({"call": lost[0], "you": lost[1]}));
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
