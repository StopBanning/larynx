//! "Send a report…": one plain text file a person can attach to an email when Larynx misbehaves, so whoever helps
//! them gets facts instead of "it doesn't work". What's in it is said at the top, and it never holds the words of a
//! dictation, a meeting's transcript or notes, or any key: only versions, the computer, the audio devices, timings
//! and errors from the log, and the shape of recent meetings (how long, how many lines, what went wrong).

use crate::meeting::Meeting;

pub const HEADER: &str = "Larynx report

This file is for the person helping you with Larynx. It holds the app's version, this computer's details and audio
devices, the app's log (timings and errors) and the length of your recent meetings. It does not hold anything you
said or dictated, any meeting transcript or summary, or your Claude key. Read it before you send it if you like.";

/// Log fields that could ever hold words someone said; dropped from every line whatever the log was told to keep.
const PRIVATE: &[&str] = &["raw", "text", "words", "transcript", "notes", "title", "summary", "key"];

/// The report: `app` (version, model), `computer` (free text from the system), the log's text, recent meetings.
pub fn build(app: &str, computer: &str, log: &str, meetings: &[Meeting], lines: usize) -> String {
    let mut out = vec![HEADER.to_string(), String::new(), "== Larynx".into(), app.trim().into(), String::new()];
    out.push("== This computer".into());
    out.push(computer.trim().into());
    out.push(String::new());
    out.push(format!("== Recent meetings ({})", meetings.len()));
    if meetings.is_empty() {
        out.push("none".into());
    }
    for m in meetings {
        let yours = m.segments.iter().filter(|s| s.speaker == "You").count();
        let notes = match &m.notes {
            Some(n) => format!("notes by {} in {:.0} s", if n.model.is_empty() { "?" } else { &n.model }, n.seconds),
            None => "no notes".into(),
        };
        out.push(format!(
            "{}  {} min, {} lines ({} yours), {}",
            m.id,
            (m.duration / 60.0).round(),
            m.segments.len(),
            yours,
            notes
        ));
    }
    out.push(String::new());
    let all: Vec<&str> = log.lines().filter(|l| !l.trim().is_empty()).collect();
    let tail = &all[all.len().saturating_sub(lines)..];
    out.push(format!("== Log (last {} of {} lines)", tail.len(), all.len()));
    for line in tail {
        out.push(scrub(line));
    }
    out.join("\n") + "\n"
}

/// One log line with anything private removed. A line that isn't JSON is kept only if it has no letters beyond an
/// event name's worth (it could be anything), otherwise replaced.
fn scrub(line: &str) -> String {
    match serde_json::from_str::<serde_json::Value>(line) {
        Ok(serde_json::Value::Object(mut o)) => {
            for k in PRIVATE {
                if o.contains_key(*k) {
                    o.insert((*k).into(), serde_json::json!("(left out)"));
                }
            }
            serde_json::Value::Object(o).to_string()
        }
        _ => "(a line that isn't from the app's log, left out)".into(),
    }
}

/// Trims a log that has grown past `max` bytes to its last half, at a line break. The app does this at start so the
/// log never fills a disk.
pub fn trimmed(log: &str, max: usize) -> Option<String> {
    if log.len() <= max {
        return None;
    }
    let mut from = log.len() - max / 2;
    while !log.is_char_boundary(from) {
        from += 1;
    }
    let rest = &log[from..];
    Some(rest.split_once('\n').map(|(_, r)| r).unwrap_or(rest).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meeting::{Notes, Segment};

    fn meeting() -> Meeting {
        let seg = |speaker: &str, text: &str| Segment { speaker: speaker.into(), start: 0.0, end: 1.0, text: text.into() };
        Meeting {
            id: "meeting-1800000000".into(),
            started: 1_800_000_000.0,
            duration: 1_250.0,
            utc_offset: 0,
            segments: vec![seg("You", "The gate code is four four one two."), seg("On the call", "Got it, thanks.")],
            notes: Some(Notes { title: "Gate code for the crew".into(), summary: vec!["The gate code is 4412.".into()], model: "claude".into(), seconds: 9.4, ..Default::default() }),
        }
    }

    #[test]
    fn nothing_said_or_secret_gets_in() {
        let log = [
            r#"{"event":"ready","load_ms":2100,"t":1}"#,
            r#"{"event":"inserted","raw":"the gate code is four four one two","text":"The gate code is 4412.","ms":420,"t":2}"#,
            r#"{"event":"error","error":"no microphone","t":3}"#,
            "a stray line with the gate code in it",
        ]
        .join("\n");
        let r = build("Larynx 0.1.0", "Windows 11, 8 GB", &log, &[meeting()], 400);
        for secret in ["gate code", "4412", "four four", "Gate code for the crew", "Got it"] {
            assert!(!r.contains(secret), "{secret:?} leaked:\n{r}");
        }
        assert!(r.contains("no microphone") && r.contains(r#""load_ms":2100"#) && r.contains(r#""ms":420"#));
        assert!(r.contains("meeting-1800000000  21 min, 2 lines (1 yours), notes by claude in 9 s"));
        assert!(r.starts_with("Larynx report"));
    }

    #[test]
    fn only_the_end_of_a_long_log() {
        let log: String = (0..1000).map(|i| format!("{{\"event\":\"tap\",\"n\":{i}}}\n")).collect();
        let r = build("", "", &log, &[], 400);
        assert!(r.contains("== Log (last 400 of 1000 lines)"));
        assert!(r.contains(r#""n":999"#) && !r.contains(r#""n":599}"#) && r.contains(r#""n":600"#));
        assert!(r.contains("== Recent meetings (0)\nnone"));
    }

    #[test]
    fn a_big_log_is_trimmed_at_a_line() {
        let log: String = (0..100).map(|i| format!("line {i}\n")).collect();
        assert_eq!(trimmed(&log, 10_000), None);
        let t = trimmed(&log, 200).unwrap();
        assert!(t.len() <= 100 && t.starts_with("line ") && t.ends_with("line 99\n"), "{t:?}");
    }
}
