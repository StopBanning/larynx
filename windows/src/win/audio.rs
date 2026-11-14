//! The microphone: WASAPI shared mode, asking Windows for 16 kHz mono float directly (its own resampler does the
//! conversion). Like the Mac, the microphone stays open for 30 s after a dictation so the next one starts at once,
//! and the last 0.2 s before the key went down is kept so the first word isn't clipped.
//!
//! `Feed` plays a WAV file in real time instead, for tests on machines with no microphone (CI).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};

const RATE: u32 = 16_000;
const PREROLL: usize = 3_200; // 0.2 s
const WARM: Duration = Duration::from_secs(30);

struct Shared {
    recording: Option<Arc<Mutex<Vec<f32>>>>,
    preroll: VecDeque<f32>,
    last_used: Instant,
}

pub struct Recorder {
    shared: Arc<Mutex<Shared>>,
    running: Arc<AtomicBool>,
    level: Arc<AtomicU32>,
    feed: Option<Arc<Vec<f32>>>,
    feed_stop: Arc<AtomicBool>,
    pub last_error: Arc<Mutex<Option<String>>>,
}

impl Recorder {
    pub fn new(feed: Option<Vec<f32>>) -> Recorder {
        Recorder {
            shared: Arc::new(Mutex::new(Shared { recording: None, preroll: VecDeque::new(), last_used: Instant::now() })),
            running: Arc::new(AtomicBool::new(false)),
            level: Arc::new(AtomicU32::new(0)),
            feed: feed.map(Arc::new),
            feed_stop: Arc::new(AtomicBool::new(false)),
            last_error: Arc::new(Mutex::new(None)),
        }
    }

    /// The loudness of the last 20 ms (0..1), for the pill's waveform.
    pub fn level(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }

    /// Starts a recording; samples arrive in the returned buffer.
    pub fn begin(&self) -> Arc<Mutex<Vec<f32>>> {
        let buffer = Arc::new(Mutex::new(Vec::with_capacity(RATE as usize * 30)));
        if let Some(feed) = &self.feed {
            self.feed_stop.store(false, Ordering::SeqCst);
            let (feed, out, stop, level) = (feed.clone(), buffer.clone(), self.feed_stop.clone(), self.level.clone());
            std::thread::spawn(move || {
                let start = Instant::now();
                for (i, piece) in feed.chunks(320).enumerate() {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    if let Some(w) = Duration::from_millis(i as u64 * 20).checked_sub(start.elapsed()) {
                        std::thread::sleep(w);
                    }
                    level.store(rms(piece).to_bits(), Ordering::Relaxed);
                    out.lock().unwrap().extend_from_slice(piece);
                }
                // The file ran out before the key was let go: silence, as a quiet room would give.
                while !stop.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_millis(20));
                    level.store(0f32.to_bits(), Ordering::Relaxed);
                    out.lock().unwrap().extend_from_slice(&[0.0; 320]);
                }
            });
            return buffer;
        }
        // Decided under the same lock the capture thread takes to stop, so a starting recording never meets a
        // microphone that is just closing.
        let start_thread = {
            let mut s = self.shared.lock().unwrap();
            buffer.lock().unwrap().extend(s.preroll.drain(..));
            s.recording = Some(buffer.clone());
            s.last_used = Instant::now();
            !self.running.swap(true, Ordering::SeqCst)
        };
        if start_thread {
            let (shared, running, level, error) = (self.shared.clone(), self.running.clone(), self.level.clone(), self.last_error.clone());
            std::thread::Builder::new()
                .name("larynx-mic".into())
                .spawn(move || {
                    if let Err(e) = capture(&shared, &running, &level) {
                        *error.lock().unwrap() = Some(e);
                    }
                    running.store(false, Ordering::SeqCst);
                })
                .ok();
        }
        buffer
    }

    /// Ends the recording. The microphone stays open (warm) for a while.
    pub fn end(&self) {
        self.feed_stop.store(true, Ordering::SeqCst);
        let mut s = self.shared.lock().unwrap();
        s.recording = None;
        s.last_used = Instant::now();
    }
}

fn rms(x: &[f32]) -> f32 {
    if x.is_empty() {
        return 0.0;
    }
    (x.iter().map(|v| v * v).sum::<f32>() / x.len() as f32).sqrt()
}

fn capture(shared: &Arc<Mutex<Shared>>, running: &AtomicBool, level: &AtomicU32) -> Result<(), String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let e = |x: windows::core::Error| x.to_string();
        let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(e)?;
        let device = devices.GetDefaultAudioEndpoint(eCapture, eConsole).map_err(|_| "no microphone".to_string())?;
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
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                1_000_000, // 100 ms buffer, in 100 ns units
                0,
                &format,
                None,
            )
            .map_err(e)?;
        let cap: IAudioCaptureClient = client.GetService().map_err(e)?;
        client.Start().map_err(e)?;
        loop {
            std::thread::sleep(Duration::from_millis(10));
            loop {
                let n = cap.GetNextPacketSize().map_err(e)?;
                if n == 0 {
                    break;
                }
                let mut data: *mut u8 = std::ptr::null_mut();
                let (mut frames, mut flags) = (0u32, 0u32);
                cap.GetBuffer(&mut data, &mut frames, &mut flags, None, None).map_err(e)?;
                let samples: Vec<f32> = if flags & (AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) != 0 || data.is_null() {
                    vec![0.0; frames as usize]
                } else {
                    std::slice::from_raw_parts(data as *const f32, frames as usize).to_vec()
                };
                cap.ReleaseBuffer(frames).map_err(e)?;
                level.store(rms(&samples).to_bits(), Ordering::Relaxed);
                let mut s = shared.lock().unwrap();
                if let Some(buf) = &s.recording {
                    buf.lock().unwrap().extend_from_slice(&samples);
                } else {
                    s.preroll.extend(samples);
                    let extra = s.preroll.len().saturating_sub(PREROLL);
                    s.preroll.drain(..extra);
                }
            }
            let mut s = shared.lock().unwrap();
            if s.recording.is_none() && s.last_used.elapsed() > WARM {
                s.preroll.clear(); // stale by the next dictation
                running.store(false, Ordering::SeqCst);
                break;
            }
        }
        let _ = client.Stop();
        Ok(())
    }
}
