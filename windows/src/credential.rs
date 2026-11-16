//! The Claude key for meeting notes. On Windows it lives in Credential Manager (Windows Credentials → "Larynx Claude
//! key"), never in a file. `ANTHROPIC_API_KEY` in the environment wins, for the command line and tests.

const TARGET: &str = "Larynx Claude key";

pub fn claude_key() -> Option<String> {
    if let Ok(k) = std::env::var("ANTHROPIC_API_KEY") {
        if !k.trim().is_empty() {
            return Some(k.trim().to_string());
        }
    }
    if std::env::var("LARYNX_DATA_DIR").is_ok() {
        return None; // tests never read the real store
    }
    read()
}

#[cfg(windows)]
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(windows)]
fn read() -> Option<String> {
    use windows::core::PCWSTR;
    use windows::Win32::Security::Credentials::{
        CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC,
    };
    let target = wide(TARGET);
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
fn read() -> Option<String> {
    None
}

/// Saves (or, given an empty key, removes) the key.
#[cfg(windows)]
pub fn save(key: &str) -> Result<(), String> {
    use windows::core::{PCWSTR, PWSTR};
    use windows::Win32::Security::Credentials::{
        CredDeleteW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    };
    let mut target = wide(TARGET);
    let key = key.trim();
    if key.is_empty() {
        unsafe {
            let _ = CredDeleteW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, None);
        }
        return Ok(());
    }
    let mut user = wide("Anthropic API key");
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
pub fn save(_key: &str) -> Result<(), String> {
    Err("keys are only stored on Windows; set ANTHROPIC_API_KEY instead".into())
}
