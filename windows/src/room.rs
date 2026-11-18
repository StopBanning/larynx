//! Rooms and microphones for the meeting tests: what the microphone hears of "You" and of the call coming out of
//! the speakers, made from the two clean tracks. Deterministic (no randomness between runs), portable, and cheap
//! (a few filters, no convolution), so CI can run a meeting in a bad room as easily as in a quiet one.
//!
//! - `clean`: your voice, plus the call a little quieter (what the tests always used).
//! - `bad`: a small hard room and a cheap laptop microphone: the call echoes off the walls for most of a second,
//!   there is fan noise and mains hum, the microphone loses the lows and highs and clips when it's loud.
//! - `headset`: a Bluetooth headset's microphone: your voice only (the call is in your ears, not the room), squeezed
//!   to the 8 kHz telephone band headsets fall back to during a call, with a little hiss.

use std::f32::consts::PI;

const RATE: f32 = 16_000.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Room {
    Clean,
    Bad,
    Headset,
}

impl Room {
    pub fn parse(name: &str) -> Option<Room> {
        match name {
            "clean" => Some(Room::Clean),
            "bad" => Some(Room::Bad),
            "headset" => Some(Room::Headset),
            _ => None,
        }
    }
}

/// What the microphone hears in this room.
pub fn mic(you: &[f32], call: &[f32], room: Room) -> Vec<f32> {
    let n = you.len().max(call.len());
    let at = |x: &[f32], i: usize| x.get(i).copied().unwrap_or(0.0);
    match room {
        Room::Clean => (0..n).map(|i| at(you, i) + 0.3 * at(call, i)).collect(),
        Room::Bad => {
            let call_echo = reverb(&delay(call, 0.02), 0.72);
            let you_room = reverb(you, 0.5);
            let mut noise = Noise(0x2545_f491);
            let mut rumble = 0.0f32;
            let mixed: Vec<f32> = (0..n)
                .map(|i| {
                    rumble = 0.97 * rumble + 0.03 * noise.next();
                    let t = i as f32 / RATE;
                    let hum = 0.004 * (2.0 * PI * 60.0 * t).sin() + 0.002 * (2.0 * PI * 120.0 * t).sin();
                    at(you, i) + 0.25 * at(&you_room, i) + 0.45 * at(call, i) + 0.35 * at(&call_echo, i) + 0.08 * rumble + hum
                })
                .collect();
            // A cheap microphone: little below 200 Hz or above 3.5 kHz, and it clips softly when it's loud.
            let band = low_pass(&high_pass(&mixed, 200.0), 3_500.0);
            band.iter().map(|x| (1.4 * x).tanh()).collect()
        }
        Room::Headset => {
            let mut noise = Noise(0x9e37_79b9);
            let near: Vec<f32> = (0..n).map(|i| at(you, i) + 0.003 * noise.next()).collect();
            telephone(&near)
        }
    }
}

/// Deterministic noise in -1..1.
struct Noise(u32);
impl Noise {
    fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        self.0 as f32 / u32::MAX as f32 * 2.0 - 1.0
    }
}

fn delay(x: &[f32], seconds: f32) -> Vec<f32> {
    let d = (seconds * RATE) as usize;
    std::iter::repeat_n(0.0, d).chain(x.iter().copied()).take(x.len()).collect()
}

/// Four feedback combs (Schroeder): a hard room's tail. `feedback` 0.72 rings for most of a second.
fn reverb(x: &[f32], feedback: f32) -> Vec<f32> {
    let mut out = vec![0.0f32; x.len()];
    for d in [557usize, 593, 641, 677] {
        let mut y = vec![0.0f32; x.len()];
        for i in 0..x.len() {
            y[i] = x[i] + if i >= d { feedback * y[i - d] } else { 0.0 };
            out[i] += 0.25 * (y[i] - x[i]);
        }
    }
    out
}

fn low_pass(x: &[f32], cutoff: f32) -> Vec<f32> {
    let a = (-2.0 * PI * cutoff / RATE).exp();
    let mut y = 0.0f32;
    x.iter()
        .map(|v| {
            y = (1.0 - a) * v + a * y;
            y
        })
        .collect()
}

fn high_pass(x: &[f32], cutoff: f32) -> Vec<f32> {
    let low = low_pass(x, cutoff);
    x.iter().zip(low).map(|(v, l)| v - l).collect()
}

/// The 8 kHz telephone band: filtered, every other sample dropped, then back to 16 kHz.
fn telephone(x: &[f32]) -> Vec<f32> {
    let steep = |x: Vec<f32>| (0..4).fold(x, |y, _| low_pass(&y, 3_400.0));
    let band = steep(high_pass(x, 300.0));
    let up: Vec<f32> = band.iter().step_by(2).flat_map(|v| [*v, *v]).take(x.len()).collect();
    steep(up)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(hz: f32, seconds: f32, level: f32) -> Vec<f32> {
        (0..(seconds * RATE) as usize).map(|i| level * (2.0 * PI * hz * i as f32 / RATE).sin()).collect()
    }
    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|v| v * v).sum::<f32>() / x.len() as f32).sqrt()
    }

    #[test]
    fn every_room_is_the_same_every_time_and_never_clips() {
        let (you, call) = (tone(440.0, 2.0, 0.6), tone(700.0, 3.0, 0.9));
        for room in [Room::Clean, Room::Bad, Room::Headset] {
            let a = mic(&you, &call, room);
            assert_eq!(a, mic(&you, &call, room), "{room:?}");
            assert_eq!(a.len(), call.len(), "{room:?}");
            if room != Room::Clean {
                assert!(a.iter().all(|v| v.abs() <= 1.0), "{room:?}");
            }
        }
    }

    #[test]
    fn the_bad_room_echoes_after_the_call_stops() {
        let mut call = tone(500.0, 1.0, 0.5);
        call.extend(vec![0.0; 16_000]);
        let silent = vec![0.0; call.len()];
        let m = mic(&silent, &call, Room::Bad);
        let tail = rms(&m[16_000 + 1_600..16_000 + 6_400]); // 0.1-0.4 s after the call stopped
        let quiet = mic(&silent, &silent, Room::Bad);
        assert!(tail > 3.0 * rms(&quiet[17_600..22_400]), "tail {tail}");
    }

    #[test]
    fn the_headset_keeps_speech_drops_highs_and_hears_no_call() {
        let silent = vec![0.0; 16_000];
        let speech = rms(&mic(&tone(1_000.0, 1.0, 0.5), &silent, Room::Headset)[4_000..]);
        let high = rms(&mic(&tone(6_000.0, 1.0, 0.5), &silent, Room::Headset)[4_000..]);
        let call = rms(&mic(&silent, &tone(1_000.0, 1.0, 0.5), Room::Headset)[4_000..]);
        assert!(speech > 0.2, "speech {speech}");
        assert!(high < 0.25 * speech, "high {high} speech {speech}");
        assert!(call < 0.01, "call {call}");
    }
}
