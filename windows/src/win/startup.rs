//! "Start with Windows": a value under the current user's Run key, so Larynx is in the tray after every restart. On
//! a computer kept on a desk to record meetings, nobody should have to find larynx.exe again.

use windows::core::{w, PCWSTR};
use windows::Win32::System::Registry::*;

const RUN: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const NAME: PCWSTR = w!("Larynx");

/// This copy of larynx.exe, quoted, as the Run key wants it.
fn command() -> Option<Vec<u16>> {
    let exe = std::env::current_exe().ok()?;
    Some(format!("\"{}\"", exe.display()).encode_utf16().chain(std::iter::once(0)).collect())
}

/// On when the Run key starts this copy of Larynx.
pub fn is_on() -> bool {
    let mut buf = [0u16; 1024];
    let mut size = (buf.len() * 2) as u32;
    let ok = unsafe { RegGetValueW(HKEY_CURRENT_USER, RUN, NAME, RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut size)) };
    if ok.is_err() {
        return false;
    }
    let n = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    command().is_some_and(|c| c[..c.len() - 1] == buf[..n])
}

pub fn set(on: bool) -> Result<(), String> {
    let r = unsafe {
        if on {
            let c = command().ok_or("can't find larynx.exe")?;
            RegSetKeyValueW(HKEY_CURRENT_USER, RUN, NAME, REG_SZ.0, Some(c.as_ptr() as *const _), (c.len() * 2) as u32)
        } else {
            RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN, NAME)
        }
    };
    if r.is_ok() || (!on && r == windows::Win32::Foundation::ERROR_FILE_NOT_FOUND) { Ok(()) } else { Err(format!("{r:?}")) }
}
