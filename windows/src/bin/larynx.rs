//! The app: no console window.
#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() {
    larynx_windows::entry(true);
}
