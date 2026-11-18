//! "Send a report…" in the tray menu: writes `Larynx report.txt` to the Desktop (crate::report says what's in it and
//! what never is), shows it in Explorer and says what to do with it. Runs on its own thread: asking Windows about the
//! computer takes a second or two.

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use windows::core::PCWSTR;
use windows::Win32::UI::Shell::{FOLDERID_Desktop, SHGetKnownFolderPath, KF_FLAG_DEFAULT};
use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONINFORMATION, MB_OK, MB_SETFOREGROUND};

const NO_WINDOW: u32 = 0x0800_0000;

/// What Windows says about this computer: version, processor, memory, disk, screens, audio devices.
const COMPUTER: &str = r#"
$o = Get-CimInstance Win32_OperatingSystem; "Windows: $($o.Caption) $($o.Version) $($o.OSArchitecture)"
$p = Get-CimInstance Win32_Processor | Select-Object -First 1; "Processor: $($p.Name.Trim()) ($($p.NumberOfLogicalProcessors) threads)"
"Memory: {0:N1} GB" -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
"Free on C: {0:N1} GB" -f ((Get-PSDrive C).Free / 1GB)
"Screens:"; Get-CimInstance Win32_VideoController | ForEach-Object { "  $($_.Name), $($_.CurrentHorizontalResolution) x $($_.CurrentVerticalResolution)" }
"Audio devices:"; Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { "  $($_.Status) $($_.FriendlyName)" }
"#;

fn desktop() -> PathBuf {
    unsafe {
        if let Ok(p) = SHGetKnownFolderPath(&FOLDERID_Desktop, KF_FLAG_DEFAULT, None) {
            if let Ok(s) = p.to_string() {
                windows::Win32::System::Com::CoTaskMemFree(Some(p.0 as *const _));
                return PathBuf::from(s);
            }
        }
    }
    std::env::var("USERPROFILE").map(|h| PathBuf::from(h).join("Desktop")).unwrap_or_else(|_| crate::data_dir())
}

/// The newest meetings, newest first.
fn recent_meetings(n: usize) -> Vec<crate::meeting::Meeting> {
    let mut paths: Vec<PathBuf> = std::fs::read_dir(crate::meeting::folder())
        .map(|d| d.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "json")).collect())
        .unwrap_or_default();
    paths.sort();
    paths.iter().rev().take(n).filter_map(|p| crate::meeting::load(p).ok()).collect()
}

/// Writes the report and shows it. `LARYNX_REPORT_DIR` (tests) writes it there instead and shows nothing.
pub fn send(app: String, log: PathBuf, done: impl FnOnce(Result<PathBuf, String>) + Send + 'static) {
    std::thread::spawn(move || {
        let computer = Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", COMPUTER])
            .creation_flags(NO_WINDOW)
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).replace("\r\n", "\n"))
            .unwrap_or_else(|e| format!("(couldn't ask Windows: {e})"));
        let log_text = std::fs::read_to_string(&log).unwrap_or_default();
        let mut text = crate::report::build(&app, &computer, &log_text, &recent_meetings(10), 400);
        // The user's name is in their folder paths; the helper doesn't need it.
        if let Ok(home) = std::env::var("USERPROFILE") {
            if !home.is_empty() {
                text = text.replace(&home, "%USERPROFILE%").replace(&home.replace('\\', "\\\\"), "%USERPROFILE%");
            }
        }
        let test_dir = std::env::var_os("LARYNX_REPORT_DIR").map(PathBuf::from);
        let path = test_dir.clone().unwrap_or_else(desktop).join("Larynx report.txt");
        let result = std::fs::write(&path, text.replace('\n', "\r\n")).map(|_| path.clone()).map_err(|e| e.to_string());
        if test_dir.is_none() {
            show(&path, &result);
        }
        done(result);
    });
}

fn show(path: &Path, result: &Result<PathBuf, String>) {
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<u16>>();
    let message = match result {
        Ok(_) => {
            let _ = Command::new("explorer").arg(format!("/select,{}", path.display())).spawn();
            "Your report is on your Desktop, called \"Larynx report\".\n\nAttach it to an email to the person who helps you with Larynx. It has no words you said and no meeting notes in it.".to_string()
        }
        Err(e) => format!("The report couldn't be saved ({e})."),
    };
    let (m, t) = (wide(&message), wide("Larynx"));
    unsafe {
        MessageBoxW(None, PCWSTR(m.as_ptr()), PCWSTR(t.as_ptr()), MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);
    }
}
