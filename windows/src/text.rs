//! The text cleanup: LarynxText (Swift, the same code the Mac runs), as `larynx-text`, a small process that cleans
//! one JSON line at a time. It starts once and stays up; a round trip over the pipes takes well under a millisecond.
//! (Loading Swift as a DLL into this process hung on Windows; a separate process also means a crash in the cleanup
//! can never take the app down: the words then go out as the model heard them.)

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

struct Proc {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

pub struct Cleanup {
    path: PathBuf,
    proc: Mutex<Option<Proc>>,
}

#[derive(Serialize, Default, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Options {
    pub mode: String,
    pub style: String,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    pub dictionary: HashMap<String, String>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    pub snippets: HashMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stages: Option<Vec<String>>,
}

#[derive(Serialize)]
struct Request<'a> {
    text: &'a str,
    #[serde(flatten)]
    options: &'a Options,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Cleaned {
    pub text: String,
    pub snippet: Option<String>,
}

pub fn library_name() -> &'static str {
    if cfg!(windows) {
        "larynx-text.exe"
    } else {
        "larynx-text"
    }
}

/// Where to look: `LARYNX_TEXT_BIN`, then next to the executable.
pub fn find_library() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("LARYNX_TEXT_BIN") {
        return Some(PathBuf::from(p));
    }
    let exe = std::env::current_exe().ok()?;
    let p = exe.parent()?.join(library_name());
    p.exists().then_some(p)
}

/// JSON with every non-ASCII character as a \u escape (only strings can hold them), so no code page can garble it.
fn ascii_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_ascii() {
            out.push(c);
        } else {
            let mut buf = [0u16; 2];
            for unit in c.encode_utf16(&mut buf) {
                out.push_str(&format!("\\u{:04x}", unit));
            }
        }
    }
    out
}

fn spawn(path: &Path) -> Result<Proc, String> {
    let mut cmd = Command::new(path);
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let mut child = cmd.spawn().map_err(|e| format!("{}: {e}", path.display()))?;
    let stdin = child.stdin.take().ok_or("no stdin")?;
    let mut stdout = BufReader::new(child.stdout.take().ok_or("no stdout")?);
    let mut line = String::new();
    stdout.read_line(&mut line).map_err(|e| e.to_string())?;
    if !line.contains("ready") {
        let _ = child.kill();
        let mut err = String::new();
        if let Some(mut e) = child.stderr.take() {
            let _ = std::io::Read::read_to_string(&mut e, &mut err);
        }
        let status = child.wait().map(|s| s.to_string()).unwrap_or_default();
        return Err(format!("larynx-text did not start (said {line:?}; {status}; stderr {err:?})"));
    }
    // Nothing reads its stderr from here on; drop it so a chatty child can never block on a full pipe.
    drop(child.stderr.take());
    Ok(Proc { child, stdin, stdout })
}

impl Cleanup {
    pub fn load(path: &Path) -> Result<Self, String> {
        let proc = spawn(path)?;
        Ok(Cleanup { path: path.to_path_buf(), proc: Mutex::new(Some(proc)) })
    }

    fn ask(proc: &mut Proc, request: &str) -> Option<String> {
        proc.stdin.write_all(request.as_bytes()).ok()?;
        proc.stdin.write_all(b"\n").ok()?;
        proc.stdin.flush().ok()?;
        let mut line = String::new();
        (proc.stdout.read_line(&mut line).ok()? > 0).then_some(line)
    }

    pub fn clean(&self, text: &str, options: &Options) -> Cleaned {
        let fallback = Cleaned { text: text.to_string(), snippet: None };
        let request = ascii_json(&serde_json::to_string(&Request { text, options }).unwrap_or_default());
        let mut guard = self.proc.lock().unwrap();
        for _ in 0..2 {
            if guard.is_none() {
                *guard = spawn(&self.path).ok();
            }
            let Some(proc) = guard.as_mut() else { break };
            if let Some(reply) = Self::ask(proc, &request) {
                return serde_json::from_str(reply.trim()).unwrap_or(fallback);
            }
            // It died: start it again once.
            let _ = proc.child.kill();
            *guard = None;
        }
        fallback
    }
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        if let Ok(mut g) = self.proc.lock() {
            if let Some(p) = g.as_mut() {
                let _ = p.child.kill();
            }
        }
    }
}

/// Runs tests/cases.json through the library exactly as the Swift tests do: every `text` case through tidy alone in
/// its mode, and every `numbers` case through the numbers stage. Returns (passed, failures).
pub fn conformance(lib: &Cleanup, cases_path: &Path) -> Result<(usize, Vec<String>), String> {
    let raw = std::fs::read_to_string(cases_path).map_err(|e| e.to_string())?;
    let cases: serde_json::Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
    let mut passed = 0;
    let mut failures = Vec::new();
    let mut check = |id: &str, input: &str, expect: &str, mode: &str, stage: &str| {
        let opts = Options { mode: mode.into(), style: "casual".into(), stages: Some(vec![stage.into()]), ..Default::default() };
        let got = lib.clean(input, &opts).text;
        if got == expect {
            passed += 1;
        } else {
            failures.push(format!("{id}: {input:?} -> {got:?}, expected {expect:?}"));
        }
    };
    for c in cases["text"].as_array().ok_or("no text cases")? {
        let s = |k: &str| c[k].as_str().unwrap_or_default().to_string();
        check(&s("id"), &s("in"), &s("expect"), &s("mode"), "tidy");
    }
    for c in cases["numbers"]["change"].as_array().ok_or("no number cases")? {
        let (i, e) = (c["in"].as_str().unwrap_or_default(), c["expect"].as_str().unwrap_or_default());
        check("numbers", i, e, "standard", "numbers");
    }
    for k in cases["numbers"]["keep"].as_array().ok_or("no number keeps")? {
        let s = k.as_str().unwrap_or_default();
        check("numbers-keep", s, s, "standard", "numbers");
    }
    Ok((passed, failures))
}

/// Which cleanup mode suits the app the words are going to, by its executable name (the Windows twin of
/// `CleanupMode.forApp(bundleID:)` on the Mac).
pub fn mode_for_exe(exe: &str) -> &'static str {
    let e = exe.to_ascii_lowercase();
    let e = e.rsplit(['\\', '/']).next().unwrap_or(&e);
    const AI: &[&str] = &[
        "claude.exe", "chatgpt.exe", "locust.exe", "cursor.exe", "code.exe", "zed.exe", "windowsterminal.exe",
        "wt.exe", "cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe", "warp.exe", "alacritty.exe", "wezterm-gui.exe",
    ];
    const EMAIL: &[&str] = &["outlook.exe", "olk.exe", "thunderbird.exe", "hxoutlook.exe"];
    const PEOPLE: &[&str] = &[
        "slack.exe", "teams.exe", "ms-teams.exe", "discord.exe", "whatsapp.exe", "telegram.exe", "notion.exe",
        "winword.exe", "signal.exe", "onenote.exe",
    ];
    if AI.contains(&e) {
        "ai"
    } else if EMAIL.contains(&e) {
        "email"
    } else if PEOPLE.contains(&e) {
        "correspondence"
    } else {
        "standard"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes() {
        assert_eq!(mode_for_exe(r"C:\Program Files\Slack\slack.exe"), "correspondence");
        assert_eq!(mode_for_exe("Code.exe"), "ai");
        assert_eq!(mode_for_exe("notepad.exe"), "standard");
        assert_eq!(mode_for_exe("OUTLOOK.EXE"), "email");
    }

    /// Runs when LARYNX_TEXT_BIN points at a built larynx-text (CI on Windows; `swift build` on a Mac).
    #[test]
    fn swift_library_matches_cases() {
        let Some(path) = std::env::var_os("LARYNX_TEXT_BIN").map(PathBuf::from) else {
            eprintln!("LARYNX_TEXT_BIN not set: skipped");
            return;
        };
        let lib = Cleanup::load(&path).unwrap();
        let cases = Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/cases.json");
        let (passed, failures) = conformance(&lib, &cases).unwrap();
        assert!(failures.is_empty(), "{} passed, failures:\n{}", passed, failures.join("\n"));
        assert!(passed > 100, "{passed}");
        let full = lib.clean("um so I think we should uh move the meeting to thursday", &Options {
            mode: "correspondence".into(),
            style: "casual".into(),
            ..Default::default()
        });
        assert_eq!(full.text, "So I think we should move the meeting to Thursday.");
        let accents = lib.clean("the café is open", &Options { mode: "standard".into(), style: "casual".into(), ..Default::default() });
        assert!(accents.text.contains("café"), "{}", accents.text);
    }
}
