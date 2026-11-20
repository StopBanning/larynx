//! Gives larynx.exe its face on Windows: the Larynx mark as its icon (so the folder, the taskbar and Alt+Tab show the
//! blue disc, not a blank program), "Larynx" as its name and version (Task Manager, the file's Properties), and a
//! manifest that turns on Windows' current look for standard controls (common controls 6) and per-monitor scaling.
//!
//! The icon is packaging/larynx.ico, made from the Mac's packaging/Larynx.icns (scripts/make-ico.sh), so both
//! platforms carry the same mark. Resources are compiled with the Windows SDK's rc.exe; where there is none, the
//! build goes on without them and says so.

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let ico = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../packaging/larynx.ico");
    println!("cargo:rerun-if-changed={}", ico.display());
    let manifest = out.join("larynx.manifest");
    std::fs::write(&manifest, MANIFEST).unwrap();
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.1.0".into());
    let nums: Vec<String> = version.split(|c: char| !c.is_ascii_digit()).filter(|s| !s.is_empty()).take(3).map(String::from).collect();
    let v = |i: usize| nums.get(i).cloned().unwrap_or_else(|| "0".into());
    let rc = out.join("larynx.rc");
    std::fs::write(
        &rc,
        format!(
            r#"#pragma code_page(65001)
1 ICON "{ico}"
1 24 "{manifest}"
1 VERSIONINFO
FILEVERSION {a},{b},{c},0
PRODUCTVERSION {a},{b},{c},0
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "FileDescription", "Larynx"
      VALUE "ProductName", "Larynx"
      VALUE "FileVersion", "{version}"
      VALUE "ProductVersion", "{version}"
      VALUE "LegalCopyright", "MIT License"
      VALUE "OriginalFilename", "larynx.exe"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"#,
            ico = escape(&ico),
            manifest = escape(&manifest),
            a = v(0),
            b = v(1),
            c = v(2),
        ),
    )
    .unwrap();
    let Some(rc_exe) = find_rc() else {
        println!("cargo:warning=rc.exe not found: larynx.exe is built without its icon and name");
        return;
    };
    let res = out.join("larynx.res");
    let status = std::process::Command::new(&rc_exe).arg("/nologo").arg("/fo").arg(&res).arg(&rc).status();
    match status {
        Ok(s) if s.success() => println!("cargo:rustc-link-arg-bins={}", res.display()),
        other => println!("cargo:warning=rc.exe failed ({other:?}): larynx.exe is built without its icon and name"),
    }
}

fn escape(p: &Path) -> String {
    p.display().to_string().replace('\\', "\\\\")
}

/// The newest Windows SDK's rc.exe for this machine.
fn find_rc() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("RC") {
        return Some(PathBuf::from(p));
    }
    let arch = if std::env::var("HOST").unwrap_or_default().starts_with("aarch64") { "arm64" } else { "x64" };
    let mut found: Vec<PathBuf> = Vec::new();
    for root in [r"C:\Program Files (x86)\Windows Kits\10\bin", r"C:\Program Files\Windows Kits\10\bin"] {
        if let Ok(dirs) = std::fs::read_dir(root) {
            for d in dirs.flatten() {
                let p = d.path().join(arch).join("rc.exe");
                if p.exists() {
                    found.push(p);
                }
            }
        }
    }
    found.sort();
    found.pop()
}

const MANIFEST: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="Larynx" version="1.0.0.0"/>
  <description>Larynx: talk instead of type</description>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0"
        processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
"#;
