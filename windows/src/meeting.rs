//! Meeting mode (docs/dev/MEETING.md): a meeting's transcript, the notes Claude writes for it, the check of those notes
//! against what was said, and the page the notes are shown on. Everything here is portable and tested on any machine;
//! the recording itself lives in `win/meeting.rs`.
//!
//! The notes request is the Mac's (`Sources/LarynxCore/ClaudeNotes.swift`) byte for byte in meaning: same model, same
//! instructions, same transcript lines, same schema, same `verify()`. Both apps write the same notes.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const MODEL: &str = "claude-opus-5-5";
pub const VERSION: &str = "2026-10-21";
pub const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    pub speaker: String,
    pub start: f64,
    pub end: f64,
    pub text: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionItem {
    pub task: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Notes {
    pub title: String,
    pub summary: Vec<String>,
    pub decisions: Vec<String>,
    pub action_items: Vec<ActionItem>,
    pub open_questions: Vec<String>,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub seconds: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Meeting {
    pub id: String,
    /// Seconds since 1970 (UTC) when the recording started.
    pub started: f64,
    pub duration: f64,
    /// Minutes east of UTC where it was recorded, so dates read in local time.
    #[serde(default)]
    pub utc_offset: i32,
    pub segments: Vec<Segment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<Notes>,
}

pub fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

impl Meeting {
    pub fn transcript(&self) -> String {
        self.segments
            .iter()
            .map(|s| format!("[{}] {}: {}", clock(s.start), s.speaker, s.text))
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The names "You" addressed ("Go ahead, Dana.", "Thanks, Priya"), in the order first said. Sentence openers like
    /// "Great," are not names. Same rule as the Mac's `addressedNames`.
    pub fn addressed_names(&self) -> Vec<String> {
        const NOT_NAMES: &[&str] = &[
            "okay",
            "ok",
            "great",
            "thanks",
            "thank",
            "morning",
            "yes",
            "yeah",
            "fine",
            "right",
            "last",
            "perfect",
            "so",
            "well",
            "sure",
            "good",
            "hi",
            "hey",
            "hello",
            "alright",
            "no",
            "wait",
            "sorry",
            "please",
            "actually",
            "anyway",
            "also",
            "then",
            "now",
            "first",
            "next",
            "everyone",
            "guys",
            "folks",
            "all",
            "afternoon",
            "evening",
            "cool",
            "nice",
            "awesome",
            "exactly",
            "true",
            "agreed",
            "absolutely",
            "anyone",
        ];
        let mut names: Vec<String> = Vec::new();
        for seg in self.segments.iter().filter(|s| s.speaker == "You") {
            let chars: Vec<char> = seg.text.chars().collect();
            let mut i = 0;
            while i < chars.len() {
                // A word starts at the beginning, or after ",.!?" and whitespace.
                let at_start = i == 0 || {
                    let mut j = i;
                    let mut saw_space = false;
                    while j > 0 && chars[j - 1].is_whitespace() {
                        j -= 1;
                        saw_space = true;
                    }
                    saw_space && j > 0 && ",.!?".contains(chars[j - 1])
                };
                if at_start && chars[i].is_ascii_uppercase() {
                    let mut k = i + 1;
                    while k < chars.len() && chars[k].is_ascii_lowercase() {
                        k += 1;
                    }
                    let len = k - i;
                    if (2..=16).contains(&len) && k < chars.len() && ",.!?".contains(chars[k]) {
                        let word: String = chars[i..k].iter().collect();
                        if !NOT_NAMES.contains(&word.to_lowercase().as_str())
                            && !names.contains(&word)
                        {
                            names.push(word);
                        }
                    }
                    i = k;
                } else {
                    i += 1;
                }
            }
        }
        names
    }

    /// One-to-one call: when "You" spoke to exactly one person by name, the call side is that person.
    pub fn naming_the_call(&self) -> Meeting {
        let names = self.addressed_names();
        let mut m = self.clone();
        if names.len() == 1 && self.segments.iter().any(|s| s.speaker == "On the call") {
            for s in &mut m.segments {
                if s.speaker == "On the call" {
                    s.speaker = names[0].clone();
                }
            }
        }
        m
    }
}

pub const INSTRUCTIONS: &str = "You write meeting notes for a busy person who was in the meeting and wants the result in plain English.
Rules:
- Use only what was said in the transcript. Never add facts, numbers, names or dates that were not said.
- Use people's names when they were said. \"You\" is the person these notes are for; write \"you\" for them.
- The summary is three to five short sentences: what the meeting was about and what came of it.
- A decision is something the people agreed on. Leave the list empty if nothing was decided.
- An action item is a task someone said they or someone else would do. Give the owner and the due date only
  when they were said; otherwise leave them empty. Never guess.
- Open questions are things raised and left unanswered.
- Short, clear sentences. No filler, no \"the speaker said\", no timestamps.";

pub const LEGEND: &str = "In the transcript, \"You\" is the person these notes are for. \"On the call\" (or \"Person 1\", \"Person 2\"...) are the
other people; work out their names from how they are addressed (\"Go ahead, Dana\" means the next person to speak
is Dana) and use the names.";

fn schema() -> Value {
    let list =
        |about: &str| json!({"type": "array", "description": about, "items": {"type": "string"}});
    json!({
        "type": "object", "additionalProperties": false,
        "required": ["title", "summary", "decisions", "actionItems", "openQuestions"],
        "properties": {
            "title": {"type": "string", "description": "A short title for the meeting, three to seven words."},
            "summary": list("Three to five short sentences: what the meeting was about and what came of it."),
            "decisions": list("Each decision as a short sentence. Empty if nothing was decided."),
            "actionItems": {"type": "array", "items": {
                "type": "object", "additionalProperties": false, "required": ["task", "owner", "due"],
                "properties": {
                    "task": {"type": "string", "description": "What will be done, as a short sentence."},
                    "owner": {"type": "string", "description": "Who will do it, only if said; otherwise empty."},
                    "due": {"type": "string", "description": "When, in the words used (\"Friday\", \"tonight\"), only if said; otherwise empty."}
                }
            }},
            "openQuestions": list("Things raised and left unanswered. Empty if none.")
        }
    })
}

/// "Monday, November 16, 2026 at 3:00 PM": when the meeting started, in the time zone it was recorded in.
pub fn when_local(started: f64, utc_offset: i32) -> String {
    let local = started + utc_offset as f64 * 60.0;
    let minutes = (local / 60.0).floor() as i64;
    let (h, m) = (minutes.rem_euclid(1440) / 60, minutes.rem_euclid(60));
    format!(
        "{} at {}:{:02} {}",
        when(local),
        if h % 12 == 0 { 12 } else { h % 12 },
        m,
        if h < 12 { "AM" } else { "PM" }
    )
}

/// The date alone ("Monday, November 16, 2026") for seconds since 1970 already in the wanted time zone.
pub fn when(started: f64) -> String {
    let days = (started / 86_400.0).floor() as i64;
    let (y, m, d) = civil(days);
    const MONTHS: [&str; 12] = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    const WEEKDAYS: [&str; 7] = [
        "Thursday",
        "Friday",
        "Saturday",
        "Sunday",
        "Monday",
        "Tuesday",
        "Wednesday",
    ];
    format!(
        "{}, {} {}, {}",
        WEEKDAYS[days.rem_euclid(7) as usize],
        MONTHS[(m - 1) as usize],
        d,
        y
    )
}

/// Days since 1970-01-01 to (year, month, day), Howard Hinnant's civil_from_days.
fn civil(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + if m <= 2 { 1 } else { 0 }, m, d)
}

/// The request body for one meeting (the Mac's `ClaudeNotes.body`).
pub fn body(meeting: &Meeting) -> String {
    let names = meeting.addressed_names();
    let mut system = format!("{INSTRUCTIONS}\n{LEGEND}");
    if !names.is_empty() {
        system += &format!("\nNames said in this meeting: {}.", names.join(", "));
    }
    system += "\nWrite in plain words a 75-year-old would read without effort. Keep every number with its unit, exactly as said.";
    let minutes = ((meeting.duration / 60.0).round() as i64).max(1);
    let user = format!(
        "A meeting on {}, about {} minute{} long.\n\n<transcript>\n{}\n</transcript>",
        when_local(meeting.started, meeting.utc_offset),
        minutes,
        if minutes == 1 { "" } else { "s" },
        meeting.transcript()
    );
    json!({
        "model": MODEL,
        "max_tokens": 16000,
        "fallbacks": "default",
        "output_config": {"effort": "high", "format": {"type": "json_schema", "schema": schema()}},
        "system": system,
        "messages": [{"role": "user", "content": user}]
    })
    .to_string()
}

#[derive(Clone, Debug, PartialEq)]
pub enum Failure {
    NoKey,
    BadKey,
    NoCredit,
    Unreachable(String),
    Refused,
    CutOff,
    Malformed(String),
    Api(u16, String),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Failure::NoKey => write!(f, "There's no Claude key yet. Right-click the Larynx icon and choose Set Claude key."),
            Failure::BadKey => write!(f, "The Claude key wasn't accepted. Right-click the Larynx icon and choose Set Claude key."),
            Failure::NoCredit => write!(f, "The Anthropic account is out of credit. Add credit at console.anthropic.com."),
            Failure::Unreachable(why) => write!(f, "Couldn't reach Claude ({why}). Check the internet connection."),
            Failure::Refused => write!(f, "Claude declined to write notes for this meeting."),
            Failure::CutOff => write!(f, "Claude's notes came back cut off."),
            Failure::Malformed(why) => write!(f, "Claude's notes came back in an unexpected shape ({why})."),
            Failure::Api(status, message) => write!(f, "Claude returned an error ({status}): {message}"),
        }
    }
}

/// Sends one HTTP POST: (url, headers, body) to (status, response body), or why it couldn't be sent.
pub type Transport<'a> =
    &'a dyn Fn(&str, &[(String, String)], &str) -> Result<(u16, String, Option<f64>), String>;

pub fn endpoint() -> String {
    let base =
        std::env::var("LARYNX_CLAUDE_URL").unwrap_or_else(|_| "https://api.anthropic.com".into());
    format!("{}/v1/messages", base.trim_end_matches('/'))
}

/// Notes for one meeting: one request, retried twice when Claude is busy or unreachable, then checked against the
/// transcript. `pause` waits between tries (a no-op in tests).
pub fn write_notes(
    meeting: &Meeting,
    key: Option<&str>,
    post: Transport,
    pause: &dyn Fn(f64),
) -> Result<Notes, Failure> {
    let key = key.filter(|k| !k.trim().is_empty()).ok_or(Failure::NoKey)?;
    let meeting = meeting.naming_the_call();
    if !meeting
        .segments
        .iter()
        .any(|s| s.text.chars().any(char::is_alphabetic))
    {
        return Err(Failure::Malformed("there was nothing to summarize".into()));
    }
    let headers: Vec<(String, String)> = vec![
        ("content-type".into(), "application/json".into()),
        ("x-api-key".into(), key.trim().into()),
        ("anthropic-version".into(), VERSION.into()),
        ("anthropic-beta".into(), FALLBACK_BETA.into()),
    ];
    let request = body(&meeting);
    let started = std::time::Instant::now();
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let (status, text, retry_after) = match post(&endpoint(), &headers, &request) {
            Ok(r) => r,
            Err(why) if attempt < 3 => {
                let _ = why;
                pause((attempt * attempt) as f64 * 2.0);
                continue;
            }
            Err(why) => return Err(Failure::Unreachable(why)),
        };
        if status == 200 {
            let mut notes = verify(parse(&text)?, &meeting);
            notes.model = "claude".into();
            notes.seconds = started.elapsed().as_secs_f64();
            return Ok(notes);
        }
        let message = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| v["error"]["message"].as_str().map(String::from))
            .unwrap_or_else(|| text.chars().take(300).collect());
        match status {
            401 | 403 => return Err(Failure::BadKey),
            400 if message.to_lowercase().contains("credit balance") => {
                return Err(Failure::NoCredit)
            }
            408 | 409 | 429 | 500..=599 if attempt < 3 => {
                pause(
                    retry_after
                        .unwrap_or((attempt * attempt) as f64 * 2.0)
                        .min(30.0),
                );
            }
            _ => return Err(Failure::Api(status, message)),
        }
    }
}

pub fn parse(text: &str) -> Result<Notes, Failure> {
    let reply: Value =
        serde_json::from_str(text).map_err(|_| Failure::Malformed("not JSON".into()))?;
    match reply["stop_reason"].as_str() {
        Some("refusal") => return Err(Failure::Refused),
        Some("max_tokens") => return Err(Failure::CutOff),
        _ => {}
    }
    let inner = reply["content"]
        .as_array()
        .and_then(|blocks| blocks.iter().rev().find(|b| b["type"] == "text"))
        .and_then(|b| b["text"].as_str())
        .and_then(|t| serde_json::from_str::<Value>(t).ok())
        .ok_or_else(|| Failure::Malformed("no notes in the reply".into()))?;
    let strings = |key: &str| -> Vec<String> {
        inner[key]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect()
            })
            .unwrap_or_default()
    };
    let items = inner["actionItems"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|it| {
                    let task = it["task"].as_str().unwrap_or("").trim().to_string();
                    (!task.is_empty()).then(|| ActionItem {
                        task,
                        owner: it["owner"].as_str().and_then(blank_to_none),
                        due: it["due"].as_str().and_then(blank_to_none),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Notes {
        title: inner["title"]
            .as_str()
            .and_then(blank_to_none)
            .unwrap_or_else(|| "Meeting".into()),
        summary: strings("summary"),
        decisions: strings("decisions"),
        action_items: items,
        open_questions: strings("openQuestions"),
        model: String::new(),
        seconds: 0.0,
    })
}

fn blank_to_none(s: &str) -> Option<String> {
    let t = s.trim();
    let blank = t.is_empty()
        || ["none", "n/a", "unknown", "not specified", "unspecified"]
            .contains(&t.to_lowercase().as_str());
    (!blank).then(|| t.to_string())
}

/// Numbers of two or more digits in the text, commas removed (single digits are too common to judge).
pub fn numbers(text: &str) -> std::collections::HashSet<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut out = std::collections::HashSet::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_digit() {
            let mut n = String::new();
            while i < chars.len() && (chars[i].is_ascii_digit() || chars[i] == ',') {
                if chars[i] != ',' {
                    n.push(chars[i]);
                }
                i += 1;
            }
            if i + 1 < chars.len() && chars[i] == '.' && chars[i + 1].is_ascii_digit() {
                n.push('.');
                i += 1;
                while i < chars.len() && chars[i].is_ascii_digit() {
                    n.push(chars[i]);
                    i += 1;
                }
            }
            if n.len() > 1 {
                out.insert(n);
            }
        } else {
            i += 1;
        }
    }
    out
}

/// The Mac's `verify()`: a line with a number nobody said is left out, an owner nobody named is dropped (the task
/// stays), a due date nobody said is dropped. A wrong name or figure in front of the reader is worse than a missing one.
pub fn verify(mut n: Notes, meeting: &Meeting) -> Notes {
    let said = meeting
        .segments
        .iter()
        .map(|s| s.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    let said_numbers = numbers(&said);
    let honest = |t: &str| numbers(&t.to_lowercase()).is_subset(&said_numbers);
    let dedupe = |items: Vec<String>| {
        let mut seen = std::collections::HashSet::new();
        items
            .into_iter()
            .filter(|s| seen.insert(s.to_lowercase()))
            .collect::<Vec<_>>()
    };
    n.summary.retain(|s| honest(s));
    n.decisions = dedupe(n.decisions.into_iter().filter(|s| honest(s)).collect());
    n.open_questions = dedupe(n.open_questions.into_iter().filter(|s| honest(s)).collect());
    let mut seen = std::collections::HashSet::new();
    n.action_items = n
        .action_items
        .into_iter()
        .filter(|it| honest(&it.task) && seen.insert(it.task.to_lowercase()))
        .map(|mut it| {
            if let Some(owner) = it.owner.clone() {
                let o = owner.trim().to_lowercase();
                let known = o == "you" || (o.chars().count() > 1 && said.contains(&o));
                if !known || o.starts_with("on the call") || o.starts_with("person") {
                    it.owner = None;
                }
            }
            if let Some(due) = &it.due {
                if !said.contains(&due.to_lowercase()) {
                    it.due = None;
                }
            }
            it
        })
        .collect();
    n
}

/// Posts with the system's curl (Windows 10 and later ship curl.exe), the tool `larynx setup` already uses. The key
/// goes in through curl's config on standard input, so it never appears in a process list.
pub fn curl_post(
    url: &str,
    headers: &[(String, String)],
    body: &str,
) -> Result<(u16, String, Option<f64>), String> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let dir = std::env::temp_dir().join(format!("larynx-notes-{}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let body_file = dir.join("request.json");
    let head_file = dir.join("headers.txt");
    std::fs::write(&body_file, body).map_err(|e| e.to_string())?;
    let quote = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let mut config = String::new();
    for (k, v) in headers {
        config += &format!("header = \"{}: {}\"\n", quote(k), quote(v));
    }
    let mut child = Command::new("curl")
        .args([
            "-sS",
            "-X",
            "POST",
            "--max-time",
            "300",
            "--config",
            "-",
            "-w",
            "\n%{http_code}",
            "-D",
        ])
        .arg(&head_file)
        .arg("--data-binary")
        .arg(format!("@{}", body_file.display()))
        .arg(url)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("curl isn't available: {e}"))?;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(config.as_bytes())
        .map_err(|e| e.to_string())?;
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let response_headers = std::fs::read_to_string(&head_file).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&dir);
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(if err.is_empty() {
            format!("curl exited with {}", out.status)
        } else {
            err
        });
    }
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let (text, code) = stdout.rsplit_once('\n').unwrap_or(("", stdout.as_str()));
    let status = code
        .trim()
        .parse::<u16>()
        .map_err(|_| format!("no HTTP status from curl ({code:?})"))?;
    let retry_after = response_headers
        .lines()
        .find_map(|l| {
            l.split_once(':')
                .filter(|(k, _)| k.trim().eq_ignore_ascii_case("retry-after"))
                .map(|(_, v)| v.trim().to_string())
        })
        .and_then(|v| v.parse::<f64>().ok());
    Ok((status, text.to_string(), retry_after))
}

pub fn sleep_seconds(s: f64) {
    std::thread::sleep(Duration::from_secs_f64(s.max(0.0)));
}

/// Where meetings are kept: <data dir>\meetings, one JSON and one page per meeting.
pub fn folder() -> PathBuf {
    crate::data_dir().join("meetings")
}

pub fn save(meeting: &Meeting, email: &str) -> Result<PathBuf, String> {
    let dir = folder();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let json = serde_json::to_string_pretty(meeting).map_err(|e| e.to_string())?;
    std::fs::write(dir.join(format!("{}.json", meeting.id)), json).map_err(|e| e.to_string())?;
    let page = dir.join(format!("{}.html", meeting.id));
    std::fs::write(&page, page_html(meeting, email)).map_err(|e| e.to_string())?;
    write_index(&dir)?;
    Ok(page)
}

pub fn load(path: &Path) -> Result<Meeting, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn pct(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The notes as plain text: what Copy and Email hand over.
pub fn plain(meeting: &Meeting) -> String {
    let mut out = String::new();
    let title = meeting
        .notes
        .as_ref()
        .map(|n| n.title.as_str())
        .unwrap_or("Meeting");
    out += &format!(
        "{title}\n{} · {} minutes\n",
        when_local(meeting.started, meeting.utc_offset),
        ((meeting.duration / 60.0).round() as i64).max(1)
    );
    if let Some(n) = &meeting.notes {
        let section = |out: &mut String, name: &str, items: &[String]| {
            if !items.is_empty() {
                *out += &format!("\n{name}\n");
                for i in items {
                    *out += &format!("• {i}\n");
                }
            }
        };
        section(&mut out, "Summary", &n.summary);
        section(&mut out, "Decisions", &n.decisions);
        section(
            &mut out,
            "To do",
            &n.action_items.iter().map(item_line).collect::<Vec<_>>(),
        );
        section(&mut out, "Still open", &n.open_questions);
    }
    out
}

fn item_line(it: &ActionItem) -> String {
    match (&it.owner, &it.due) {
        (Some(o), Some(d)) => format!("{} ({o}, {d})", it.task),
        (Some(o), None) => format!("{} ({o})", it.task),
        (None, Some(d)) => format!("{} ({d})", it.task),
        (None, None) => it.task.clone(),
    }
}

/// The meeting's page: large type, high contrast, three buttons (Email this to me, Copy, Print), the notes, and
/// everything that was said underneath. Opens in the default browser; works with no internet.
pub fn page_html(meeting: &Meeting, email: &str) -> String {
    let title = meeting
        .notes
        .as_ref()
        .map(|n| n.title.clone())
        .unwrap_or_else(|| "Meeting".into());
    let minutes = ((meeting.duration / 60.0).round() as i64).max(1);
    let mut body = String::new();
    match &meeting.notes {
        Some(n) => {
            let mut section = |name: &str, items: &[String]| {
                if !items.is_empty() {
                    body += &format!("<h2>{}</h2><ul>{}</ul>", esc(name), items.iter().map(|i| format!("<li>{}</li>", esc(i))).collect::<String>());
                }
            };
            section("Summary", &n.summary);
            section("Decisions", &n.decisions);
            section("To do", &n.action_items.iter().map(item_line).collect::<Vec<_>>());
            section("Still open", &n.open_questions);
            if n.model == "claude" {
                body += "<p class=quiet>Summary written by Claude.</p>";
            }
        }
        None => body += "<p class=note>There's no summary for this meeting yet. Everything that was said is below. To try again, right-click the Larynx icon and choose Write the summary again.</p>",
    }
    let said: String = meeting
        .segments
        .iter()
        .map(|s| {
            format!(
                "<div class=line><div class=who>{} · {}</div><div>{}</div></div>",
                esc(&s.speaker),
                clock(s.start),
                esc(&s.text)
            )
        })
        .collect();
    let mailto = format!(
        "mailto:{}?subject={}&body={}",
        pct(email),
        pct(&title),
        pct(&plain(meeting))
    );
    format!(
        r#"<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>{title}</title><style>
body{{font:20px/1.5 "Segoe UI",system-ui,sans-serif;color:#111;background:#fff;max-width:46em;margin:0 auto;padding:32px 24px 80px}}
h1{{font-size:2em;line-height:1.2;margin:0 0 6px}} h2{{font-size:1.3em;margin:28px 0 8px}}
.when{{color:#444;margin:0 0 22px}} .quiet{{color:#555;font-size:.8em}} .note{{background:#fff6d6;padding:14px 16px;border-radius:10px}}
.buttons{{display:flex;gap:12px;flex-wrap:wrap}} button,a.button{{font:inherit;font-size:.95em;padding:12px 20px;border-radius:10px;border:2px solid #222;background:#fff;color:#111;cursor:pointer;text-decoration:none}}
button:hover,a.button:hover{{background:#f0f0f0}} li{{margin:6px 0}} details{{margin-top:34px}} summary{{font-size:1.2em;font-weight:600;cursor:pointer}}
.line{{margin:14px 0}} .who{{font-size:.75em;font-weight:600;color:#555}} #copied{{color:#176b2c;font-weight:600}}
@media print{{.buttons{{display:none}} details{{display:block}}}}
</style></head><body>
<h1>{title}</h1><p class=when>{when} · {minutes} minute{s}</p>
<div class=buttons><a class=button href="{mailto}">Email this to me</a><button onclick="copyNotes()">Copy</button><button onclick="window.print()">Print</button> <span id=copied></span></div>
{body}
<details><summary>Everything that was said</summary>{said}</details>
<textarea id=plain style="position:absolute;left:-9999px">{plain}</textarea>
<script>function copyNotes(){{var t=document.getElementById('plain').value;function done(){{document.getElementById('copied').textContent='Copied'}}
if(navigator.clipboard){{navigator.clipboard.writeText(t).then(done,function(){{fallback()}})}}else{{fallback()}}
function fallback(){{var a=document.getElementById('plain');a.select();document.execCommand('copy');done()}}}}</script>
</body></html>"#,
        title = esc(&title),
        when = when_local(meeting.started, meeting.utc_offset),
        s = if minutes == 1 { "" } else { "s" },
        plain = esc(&plain(meeting)),
    )
}

/// The Meetings page: every meeting, newest first, each a link to its page.
pub fn write_index(dir: &Path) -> Result<(), String> {
    let mut meetings: Vec<Meeting> = std::fs::read_dir(dir)
        .map_err(|e| e.to_string())?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().map(|x| x == "json").unwrap_or(false))
        .filter_map(|e| load(&e.path()).ok())
        .collect();
    meetings.sort_by(|a, b| {
        b.started
            .partial_cmp(&a.started)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let rows: String = meetings
        .iter()
        .map(|m| {
            let title = m
                .notes
                .as_ref()
                .map(|n| n.title.clone())
                .unwrap_or_else(|| "Meeting (no summary yet)".into());
            format!(
                "<li><a href=\"{}.html\">{}</a><div class=when>{}</div></li>",
                esc(&m.id),
                esc(&title),
                when_local(m.started, m.utc_offset)
            )
        })
        .collect();
    let page = format!(
        r#"<!doctype html><html lang=en><head><meta charset=utf-8><title>Your meetings</title><style>
body{{font:20px/1.5 "Segoe UI",system-ui,sans-serif;max-width:46em;margin:0 auto;padding:32px 24px}} h1{{font-size:2em}}
li{{margin:14px 0;list-style:none}} a{{font-size:1.15em;color:#0b4fb3}} .when{{color:#555;font-size:.85em}} ul{{padding:0}}
</style></head><body><h1>Your meetings</h1><ul>{}</ul></body></html>"#,
        if rows.is_empty() {
            "<li>No meetings yet.</li>".to_string()
        } else {
            rows
        }
    );
    std::fs::write(dir.join("index.html"), page).map_err(|e| e.to_string())
}

/// Splits a track into utterances at pauses (energy, 20 ms frames): each piece is (start sample, end sample), at
/// most `max_seconds` long, ignoring stretches with no speech. Rate is 16 kHz.
pub fn utterances(samples: &[f32], max_seconds: f64) -> Vec<(usize, usize)> {
    const FRAME: usize = 320;
    let frames: Vec<f32> = samples
        .chunks(FRAME)
        .map(|c| (c.iter().map(|x| x * x).sum::<f32>() / c.len() as f32).sqrt())
        .collect();
    if frames.is_empty() {
        return vec![];
    }
    let mut sorted = frames.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let floor = sorted[sorted.len() / 10];
    let threshold = (floor * 3.0).max(0.006);
    let max_frames = (max_seconds * 50.0) as usize;
    let (mut out, mut start, mut quiet) = (Vec::new(), None::<usize>, 0usize);
    for (i, &e) in frames.iter().enumerate() {
        let loud = e > threshold;
        match start {
            None if loud => {
                start = Some(i.saturating_sub(10));
                quiet = 0;
            }
            Some(s) => {
                quiet = if loud { 0 } else { quiet + 1 };
                if quiet >= 30 || i - s >= max_frames {
                    let end = if quiet >= 30 { i - quiet + 10 } else { i };
                    if end > s + 15 {
                        out.push((s * FRAME, (end * FRAME).min(samples.len())));
                    }
                    start = None;
                }
            }
            None => {}
        }
    }
    if let Some(s) = start {
        if frames.len() > s + 15 {
            out.push((s * FRAME, samples.len()));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn meeting() -> Meeting {
        let seg = |speaker: &str, start: f64, text: &str| Segment {
            speaker: speaker.into(),
            start,
            end: start + 4.0,
            text: text.into(),
        };
        Meeting {
            id: "t".into(),
            started: 1_800_000_000.0,
            duration: 300.0,
            utc_offset: -480,
            segments: vec![
                seg("On the call", 0.0, "The tile is back-ordered for six weeks. I can send photos of two in stock tonight."),
                seg("You", 6.0, "Thanks, Priya. Send them tonight and we'll switch if one is close."),
                seg("On the call", 10.0, "The budget is sixty two thousand five hundred, so 62,500 with the faucets."),
            ],
            notes: None,
        }
    }

    fn reply(notes: &str, stop: &str) -> String {
        json!({"type": "message", "stop_reason": stop, "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": notes}]}).to_string()
    }

    const GOOD: &str = r#"{"title":"Renovation schedule","summary":["Priya's tile is back-ordered for six weeks.","The budget is 62,500."],"decisions":["Switch tile if one in stock is close."],"actionItems":[{"task":"Send photos of two tiles in stock","owner":"Priya","due":"tonight"},{"task":"Order 900 tiles","owner":"Bob","due":"Friday"}],"openQuestions":[]}"#;

    #[test]
    fn the_request_matches_the_mac() {
        let sent = RefCell::new(Vec::new());
        let post = |url: &str, headers: &[(String, String)], body: &str| {
            sent.borrow_mut()
                .push((url.to_string(), headers.to_vec(), body.to_string()));
            Ok((200, reply(GOOD, "end_turn"), None))
        };
        write_notes(&meeting(), Some("test-key"), &post, &|_| {}).unwrap();
        let sent = sent.borrow();
        assert_eq!(sent.len(), 1);
        let (url, headers, body) = &sent[0];
        assert_eq!(url, "https://api.anthropic.com/v1/messages");
        let header = |k: &str| {
            headers
                .iter()
                .find(|(h, _)| h == k)
                .map(|(_, v)| v.as_str())
        };
        assert_eq!(header("x-api-key"), Some("test-key"));
        assert_eq!(header("anthropic-version"), Some("2026-10-21"));
        assert_eq!(
            header("anthropic-beta"),
            Some("server-side-fallback-2026-07-01")
        );
        let body: Value = serde_json::from_str(body).unwrap();
        assert_eq!(body["model"], "claude-opus-5-5");
        assert!(body.get("thinking").is_none());
        assert_eq!(body["fallbacks"], "default");
        assert_eq!(body["output_config"]["effort"], "high");
        assert_eq!(body["output_config"]["format"]["type"], "json_schema");
        let user = body["messages"][0]["content"].as_str().unwrap();
        assert!(
            user.contains("[00:00] Priya: The tile is back-ordered"),
            "{user}"
        ); // one-to-one call named
        assert!(user.contains("about 5 minutes long"));
        assert!(
            user.starts_with("A meeting on Friday, January 15, 2027 at 12:00 AM"),
            "{user}"
        ); // 08:00 UTC is midnight in California
        assert!(body["system"]
            .as_str()
            .unwrap()
            .contains("Names said in this meeting: Priya."));
    }

    #[test]
    fn notes_are_read_and_checked_against_what_was_said() {
        let post =
            |_: &str, _: &[(String, String)], _: &str| Ok((200, reply(GOOD, "end_turn"), None));
        let notes = write_notes(&meeting(), Some("k"), &post, &|_| {}).unwrap();
        assert_eq!(notes.title, "Renovation schedule");
        assert_eq!(notes.model, "claude");
        assert_eq!(notes.summary.len(), 2); // "62,500" was said
        assert_eq!(notes.action_items.len(), 1); // "900 tiles" was not
        assert_eq!(notes.action_items[0].owner.as_deref(), Some("Priya"));
        assert_eq!(notes.action_items[0].due.as_deref(), Some("tonight"));
    }

    #[test]
    fn busy_is_retried_and_failures_say_what_to_do() {
        let tries = RefCell::new(0);
        let post = |_: &str, _: &[(String, String)], _: &str| {
            *tries.borrow_mut() += 1;
            if *tries.borrow() == 1 {
                Ok((
                    529,
                    r#"{"error":{"message":"Overloaded"}}"#.into(),
                    Some(1.0),
                ))
            } else {
                Ok((200, reply(GOOD, "end_turn"), None))
            }
        };
        assert!(write_notes(&meeting(), Some("k"), &post, &|_| {}).is_ok());
        assert_eq!(*tries.borrow(), 2);

        let fails = |status: u16, body: &str| {
            let body = body.to_string();
            let post =
                move |_: &str, _: &[(String, String)], _: &str| Ok((status, body.clone(), None));
            write_notes(&meeting(), Some("k"), &post, &|_| {}).unwrap_err()
        };
        assert_eq!(
            fails(401, r#"{"error":{"message":"invalid x-api-key"}}"#),
            Failure::BadKey
        );
        assert_eq!(
            fails(
                400,
                r#"{"error":{"message":"Your credit balance is too low to access the Anthropic API."}}"#
            ),
            Failure::NoCredit
        );
        assert_eq!(fails(200, &reply("{}", "refusal")), Failure::Refused);
        assert_eq!(
            fails(200, &reply("{\"title\":", "max_tokens")),
            Failure::CutOff
        );
        let none = |_: &str, _: &[(String, String)], _: &str| Ok((200, String::new(), None));
        assert_eq!(
            write_notes(&meeting(), None, &none, &|_| {}).unwrap_err(),
            Failure::NoKey
        );
        let down =
            |_: &str, _: &[(String, String)], _: &str| Err("Could not resolve host".to_string());
        assert!(matches!(
            write_notes(&meeting(), Some("k"), &down, &|_| {}),
            Err(Failure::Unreachable(_))
        ));
        assert!(Failure::NoCredit
            .to_string()
            .contains("console.anthropic.com"));
    }

    #[test]
    fn names_and_numbers_follow_the_mac_rules() {
        let m = meeting();
        assert_eq!(m.addressed_names(), vec!["Priya"]);
        let n = numbers("62,500 dollars, 3 things, 1.5 hours and 12");
        assert!(n.contains("62500") && n.contains("1.5") && n.contains("12") && !n.contains("3"));
        assert_eq!(clock(3725.0), "1:02:05");
        assert_eq!(when(0.0), "Thursday, January 1, 1970");
    }

    #[test]
    fn the_page_is_large_plain_and_escaped() {
        let mut m = meeting();
        m.notes = Some(Notes {
            title: "Tiles & <budget>".into(),
            summary: vec!["A".into()],
            model: "claude".into(),
            ..Default::default()
        });
        let page = page_html(&m, "dad@example.com");
        assert!(page.contains("Tiles &amp; &lt;budget&gt;"));
        assert!(
            page.contains("Email this to me")
                && page.contains("window.print()")
                && page.contains("Everything that was said")
        );
        assert!(page.contains("mailto:dad%40example.com?subject=Tiles%20%26%20%3Cbudget%3E"));
        assert!(page.contains("Summary written by Claude."));
        m.notes = None;
        assert!(page_html(&m, "").contains("no summary for this meeting yet"));
    }

    #[test]
    fn pauses_split_a_track_into_utterances() {
        let mut s = vec![0.0f32; 16_000]; // 1 s silence
        s.extend((0..32_000).map(|i| (i as f32 * 0.05).sin() * 0.3)); // 2 s speech
        s.extend(vec![0.0f32; 16_000]);
        s.extend((0..16_000).map(|i| (i as f32 * 0.05).sin() * 0.3)); // 1 s speech
        let pieces = utterances(&s, 25.0);
        assert_eq!(pieces.len(), 2, "{pieces:?}");
        assert!(pieces[0].0 < 16_000 && pieces[0].1 > 46_000 && pieces[0].1 < 60_000);
    }
}
