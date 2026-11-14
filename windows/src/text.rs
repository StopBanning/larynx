//! The text cleanup: LarynxText (Swift, the same code the Mac runs) through its small C door, LarynxTextC.

use libloading::{Library, Symbol};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};

type CleanFn = unsafe extern "C" fn(*const c_char, *const c_char) -> *mut c_char;
type FreeFn = unsafe extern "C" fn(*mut c_char);
type WarmFn = unsafe extern "C" fn();

pub struct Cleanup {
    _lib: Library,
    clean: CleanFn,
    free: FreeFn,
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

#[derive(Deserialize, Debug, Clone)]
pub struct Cleaned {
    pub text: String,
    pub snippet: Option<String>,
}

pub fn library_name() -> &'static str {
    if cfg!(windows) {
        "LarynxTextC.dll"
    } else if cfg!(target_os = "macos") {
        "libLarynxTextC.dylib"
    } else {
        "libLarynxTextC.so"
    }
}

/// Where to look: `LARYNX_TEXT_LIB`, then next to the executable.
pub fn find_library() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("LARYNX_TEXT_LIB") {
        return Some(PathBuf::from(p));
    }
    let exe = std::env::current_exe().ok()?;
    let p = exe.parent()?.join(library_name());
    p.exists().then_some(p)
}

impl Cleanup {
    pub fn load(path: &Path) -> Result<Self, String> {
        unsafe {
            let lib = Library::new(path).map_err(|e| format!("{}: {e}", path.display()))?;
            let clean: Symbol<CleanFn> = lib.get(b"larynx_clean\0").map_err(|e| e.to_string())?;
            let free: Symbol<FreeFn> = lib.get(b"larynx_free\0").map_err(|e| e.to_string())?;
            let (clean, free) = (*clean, *free);
            if let Ok(warm) = lib.get::<WarmFn>(b"larynx_warm\0") {
                warm();
            }
            Ok(Cleanup { _lib: lib, clean, free })
        }
    }

    pub fn clean(&self, text: &str, options: &Options) -> Cleaned {
        let fallback = Cleaned { text: text.to_string(), snippet: None };
        let (Ok(t), Ok(o)) = (CString::new(text), CString::new(serde_json::to_string(options).unwrap_or_default())) else {
            return fallback;
        };
        unsafe {
            let p = (self.clean)(t.as_ptr(), o.as_ptr());
            if p.is_null() {
                return fallback;
            }
            let json = CStr::from_ptr(p).to_string_lossy().into_owned();
            (self.free)(p);
            serde_json::from_str(&json).unwrap_or(fallback)
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

    /// Runs when LARYNX_TEXT_LIB points at a built LarynxTextC (CI on Windows; `swift build` on a Mac).
    #[test]
    fn swift_library_matches_cases() {
        let Some(path) = std::env::var_os("LARYNX_TEXT_LIB").map(PathBuf::from) else {
            eprintln!("LARYNX_TEXT_LIB not set: skipped");
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
    }
}
