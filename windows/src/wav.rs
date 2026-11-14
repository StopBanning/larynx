//! WAV files in, 16 kHz mono f32 out (what the speech model wants).

use std::path::Path;

pub const RATE: u32 = 16_000;

/// Reads a PCM16, PCM24, PCM32 or float32 WAV file, mixes it to mono and resamples it to 16 kHz.
pub fn read(path: &Path) -> Result<Vec<f32>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    parse(&bytes).map_err(|e| format!("{}: {e}", path.display()))
}

pub fn parse(bytes: &[u8]) -> Result<Vec<f32>, String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a WAV file".into());
    }
    let (mut format, mut channels, mut rate, mut bits) = (0u16, 0u16, 0u32, 0u16);
    let mut data: Option<&[u8]> = None;
    let mut i = 12;
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let size = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().unwrap()) as usize;
        let body = &bytes[i + 8..(i + 8 + size).min(bytes.len())];
        if id == b"fmt " && body.len() >= 16 {
            format = u16::from_le_bytes([body[0], body[1]]);
            channels = u16::from_le_bytes([body[2], body[3]]);
            rate = u32::from_le_bytes(body[4..8].try_into().unwrap());
            bits = u16::from_le_bytes([body[14], body[15]]);
            if format == 0xFFFE && body.len() >= 26 {
                format = u16::from_le_bytes([body[24], body[25]]); // WAVE_FORMAT_EXTENSIBLE: the real format's GUID starts here
            }
        } else if id == b"data" {
            data = Some(body);
        }
        i += 8 + size + (size & 1);
    }
    let data = data.ok_or("no data chunk")?;
    if channels == 0 || rate == 0 {
        return Err("no fmt chunk".into());
    }
    let frame = (bits as usize / 8) * channels as usize;
    if frame == 0 {
        return Err("bad sample size".into());
    }
    let sample = |b: &[u8]| -> f32 {
        match (format, bits) {
            (1, 16) => i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0,
            (1, 24) => (i32::from_le_bytes([0, b[0], b[1], b[2]]) >> 8) as f32 / 8_388_608.0,
            (1, 32) => i32::from_le_bytes(b[..4].try_into().unwrap()) as f32 / 2_147_483_648.0,
            (3, 32) => f32::from_le_bytes(b[..4].try_into().unwrap()),
            _ => 0.0,
        }
    };
    if !matches!((format, bits), (1, 16) | (1, 24) | (1, 32) | (3, 32)) {
        return Err(format!("unsupported WAV format {format}/{bits}-bit"));
    }
    let step = bits as usize / 8;
    let mono: Vec<f32> = data
        .chunks_exact(frame)
        .map(|f| (0..channels as usize).map(|c| sample(&f[c * step..])).sum::<f32>() / channels as f32)
        .collect();
    Ok(resample(&mono, rate, RATE))
}

/// Linear-interpolation resampler with a light low-pass when going down. Good enough for speech into an ASR model.
pub fn resample(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || input.is_empty() {
        return input.to_vec();
    }
    let source: Vec<f32> = if from > to {
        // Box filter as wide as the decimation ratio: removes most of what would alias.
        let width = (from as f32 / to as f32).round().max(1.0) as usize;
        let mut acc = 0.0f32;
        let mut out = Vec::with_capacity(input.len());
        for (i, x) in input.iter().enumerate() {
            acc += x;
            if i >= width {
                acc -= input[i - width];
            }
            out.push(acc / width.min(i + 1) as f32);
        }
        out
    } else {
        input.to_vec()
    };
    let ratio = from as f64 / to as f64;
    let n = ((source.len() as f64) / ratio).floor() as usize;
    (0..n)
        .map(|i| {
            let pos = i as f64 * ratio;
            let j = pos.floor() as usize;
            let frac = (pos - j as f64) as f32;
            let a = source[j];
            let b = *source.get(j + 1).unwrap_or(&a);
            a + (b - a) * frac
        })
        .collect()
}

/// Writes 16 kHz mono PCM16, for keeping a recording next to a bug report.
pub fn write(path: &Path, samples: &[f32]) -> std::io::Result<()> {
    let mut out = Vec::with_capacity(44 + samples.len() * 2);
    let data_len = (samples.len() * 2) as u32;
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&RATE.to_le_bytes());
    out.extend_from_slice(&(RATE * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
    }
    std::fs::write(path, out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let tone: Vec<f32> = (0..16000).map(|i| (i as f32 * 0.05).sin() * 0.5).collect();
        let dir = std::env::temp_dir().join("larynx-wav-test.wav");
        write(&dir, &tone).unwrap();
        let back = read(&dir).unwrap();
        assert_eq!(back.len(), tone.len());
        assert!(back.iter().zip(&tone).all(|(a, b)| (a - b).abs() < 1e-3));
        let _ = std::fs::remove_file(dir);
    }

    #[test]
    fn resample_length() {
        let x = vec![0.0f32; 48000];
        assert_eq!(resample(&x, 48000, 16000).len(), 16000);
        assert_eq!(resample(&x[..8000], 8000, 16000).len(), 16000);
    }

    #[test]
    fn fixture_reads() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/fixtures/report.wav");
        let s = read(&path).unwrap();
        assert!(s.len() > RATE as usize * 3 / 2, "{} samples", s.len());
    }
}
