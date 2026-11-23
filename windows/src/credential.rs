//! The keys for meeting notes, Claude's and Gemini's. On Windows they live in Credential Manager (Windows Credentials
//! → "Larynx Claude key", "Larynx Gemini key"), never in a file. `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` in the
//! environment win, for the command line and tests.

const TARGET: &str = "Larynx Claude key";
const GEMINI_TARGET: &str = "Larynx Gemini key";

pub fn claude_key() -> Option<String> {
    stored("ANTHROPIC_API_KEY", TARGET)
}

pub fn gemini_key() -> Option<String> {
    stored("GEMINI_API_KEY", GEMINI_TARGET)
}

pub fn save(key: &str) -> Result<(), String> {
    save_to(TARGET, "Anthropic API key", key)
}

pub fn save_gemini(key: &str) -> Result<(), String> {
    save_to(GEMINI_TARGET, "Gemini API key", key)
}

fn stored(env: &str, target: &str) -> Option<String> {
    if let Ok(k) = std::env::var(env) {
        if !k.trim().is_empty() {
            return Some(k.trim().to_string());
        }
    }
    if std::env::var("LARYNX_DATA_DIR").is_ok() {
        return None; // tests never read the real store
    }
    read(target)
}

#[cfg(windows)]
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(windows)]
fn read(target: &str) -> Option<String> {
    use windows::core::PCWSTR;
    use windows::Win32::Security::Credentials::{
        CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC,
    };
    let target = wide(target);
    let mut found: *mut CREDENTIALW = std::ptr::null_mut();
    unsafe {
        CredReadW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, None, &mut found).ok()?;
        let c = &*found;
        let blob =
            std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize).to_vec();
        CredFree(found as *const core::ffi::c_void);
        String::from_utf8(blob)
            .ok()
            .filter(|k| !k.trim().is_empty())
    }
}

#[cfg(not(windows))]
fn read(_target: &str) -> Option<String> {
    None
}

/// Saves (or, given an empty key, removes) a key.
#[cfg(windows)]
fn save_to(target: &str, user: &str, key: &str) -> Result<(), String> {
    use windows::core::{PCWSTR, PWSTR};
    use windows::Win32::Security::Credentials::{
        CredDeleteW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    };
    let mut target = wide(target);
    let key = key.trim();
    if key.is_empty() {
        unsafe {
            let _ = CredDeleteW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, None);
        }
        return Ok(());
    }
    let mut user = wide(user);
    let mut blob = key.as_bytes().to_vec();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: PWSTR(target.as_mut_ptr()),
        UserName: PWSTR(user.as_mut_ptr()),
        CredentialBlobSize: blob.len() as u32,
        CredentialBlob: blob.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        ..Default::default()
    };
    unsafe { CredWriteW(&credential, 0) }
        .map_err(|e| format!("couldn't save the key in Credential Manager: {e}"))
}

#[cfg(not(windows))]
fn save_to(_target: &str, _user: &str, _key: &str) -> Result<(), String> {
    Err("keys are only stored on Windows; set ANTHROPIC_API_KEY or GEMINI_API_KEY instead".into())
}
