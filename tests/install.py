#!/usr/bin/env python3
"""Install test (R8): what someone who isn't Colin gets from scripts/install.sh.

    python3 tests/install.py

Runs the installer with HOME set to a new, empty folder, ad-hoc signing (no identity from this Mac), no model
warm-up and nothing opened, then checks the bundle: it exists, is ad-hoc signed, has the bundle id, the icon and the
microphone text, its binary runs, the new home holds no Larynx data (so the first launch starts at setup), and the uninstall script
then leaves that home clean.
Permissions (microphone, accessibility, input monitoring) cannot be tested this way.

The new home is under ~/work/scratch (the startup disk) and is deleted afterwards. This never restarts, opens or
replaces the Larynx you use: install.sh's LARYNX_NO_OPEN skips that, and the bundle lands in the new home.
"""
import os, plistlib, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    scratch = Path.home() / "work/scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    home = Path(tempfile.mkdtemp(prefix="larynx-install-", dir=scratch))
    failures = []

    def check(ok, what):
        print(f"{'ok ' if ok else 'FAIL'} {what}")
        if not ok: failures.append(what)

    try:
        env = dict(os.environ, HOME=str(home), LARYNX_SIGN="adhoc", LARYNX_NO_WARM="1", LARYNX_NO_OPEN="1")
        r = subprocess.run(["zsh", str(ROOT / "scripts/install.sh")], env=env, capture_output=True, text=True, timeout=1800)
        check(r.returncode == 0, "install.sh finished")
        check(not (home / "Library/Application Support/Larynx").exists(), "no Larynx data in the new home (first launch starts at setup)")
        app = home / "Applications/Larynx.app"
        binary = app / "Contents/MacOS/larynx"
        check(binary.exists(), "Larynx.app is in the new home's Applications")
        if binary.exists():
            sig = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True).stderr
            check("Signature=adhoc" in sig, "signed ad hoc (no identity from this Mac)")
            check(subprocess.run(["codesign", "--verify", str(app)], capture_output=True).returncode == 0, "signature verifies")
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            check(info.get("CFBundleIdentifier") == "com.automatedworkflow.larynx", "bundle id")
            check(bool(info.get("NSMicrophoneUsageDescription")), "microphone usage text")
            check((app / "Contents/Resources/Larynx_LarynxText.bundle").exists(), "text resources travel with the app")
            check(info.get("CFBundleIconFile") == "Larynx" and (app / "Contents/Resources/Larynx.icns").exists(), "app icon")
            run = subprocess.run([str(binary), "tidy", "um so this is a test"], env=dict(env, LARYNX_DATA_DIR=str(home / "data")), capture_output=True, text=True, timeout=60)
            check(run.returncode == 0 and run.stdout.strip() == "So this is a test", "the app's binary runs")
            # Uninstall, files only (never quits an app or touches settings or permissions): the new home is left clean.
            (home / "Library/Application Support/Larynx").mkdir(parents=True, exist_ok=True)
            (home / "Documents").mkdir(exist_ok=True)
            (home / "Documents/keep.txt").write_text("not Larynx's")
            un = subprocess.run(["zsh", str(ROOT / "scripts/uninstall.sh"), "--files-only", "--yes"], env=env, capture_output=True, text=True, timeout=60)
            check(un.returncode == 0 and not app.exists() and not (home / "Library/Application Support/Larynx").exists()
                  and (home / "Documents/keep.txt").exists(), "uninstall removes the app and its data, and nothing else")
        if failures:
            print("\n--- install.sh output\n" + (r.stdout + r.stderr)[-2000:])
    finally:
        shutil.rmtree(home, ignore_errors=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
