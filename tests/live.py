#!/usr/bin/env python3
"""Live paste test (PLAN-v1 B2): a recording goes through the real listen path and is pasted into Larynx's own
capture window, never into another app. It brings a window to the front, so it only runs under
scripts/when-idle.sh (keyboard and mouse idle; stops the moment you touch them):

    scripts/when-idle.sh python3 tests/live.py

Checks the words arrive in the capture window exactly once, both by paste and (with the paste dropped on purpose) by
the verify-and-fall-back path, reports the time from transcript to text on screen,
then gives the front back to the app that had it. Your history and clipboard are untouched (LARYNX_DATA_DIR is a
temporary folder; the clipboard is restored).
"""
import json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = os.environ.get("LARYNX_BIN", str(ROOT / ".build/release/larynx"))
MODELS = os.path.expanduser("~/Library/Application Support/Larynx/models")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def front_bundle():
    out = subprocess.run(["lsappinfo", "info", "-only", "bundleid", subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()],
                         capture_output=True, text=True).stdout
    bundle = out.split("=")[-1].strip().strip('"')
    return bundle if "." in bundle else None


def capture_app(work):
    """The fresh build wrapped as a throwaway app (its own bundle id), because macOS only brings an app launched
    through LaunchServices to the front; a background command-line process can't take focus."""
    app = Path(work) / "LarynxCaptureTest.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy(BIN, app / "Contents/MacOS/larynx")
    (app / "Contents/Info.plist").write_text("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.automatedworkflow.larynx.capture-test</string>
  <key>CFBundleName</key><string>Larynx Capture Test</string>
  <key>CFBundleExecutable</key><string>larynx</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
""")
    bundle = Path(BIN).parent / "Larynx_LarynxText.bundle"
    if bundle.exists(): shutil.copytree(bundle, app / "Contents/Resources/Larynx_LarynxText.bundle")
    # Ad hoc signature for the throwaway bundle (no keychain, no identity): macOS won't launch it otherwise.
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def run_case(name, extra_env, want_delivery, prefill="", expect=lambda text: text):
    work = tempfile.mkdtemp(dir=os.path.expanduser("~/work/scratch"), prefix="larynx-live-")
    out = Path(work) / "capture.jsonl"
    out.touch()
    cap_pid = None
    try:
        app = capture_app(work)
        # A bundle macOS has never seen can fail its first launch (-10810) until LaunchServices registers it.
        subprocess.run([LSREGISTER, "-f", str(app)], capture_output=True)
        for attempt in range(4):
            if subprocess.run(["open", "-n", str(app), "--stdout", str(out), "--args", "capture-window", "--seconds", "40",
                               "--prefill", prefill],
                              capture_output=True).returncode == 0: break
            time.sleep(1)
        else:
            return False, f"{name}: could not launch the capture window"
        lines, deadline = [], time.time() + 15
        while time.time() < deadline and not lines:
            lines = [json.loads(l) for l in out.read_text().splitlines() if l.strip()]
            time.sleep(0.1)
        ready = lines[0] if lines else {}
        cap_pid = ready.get("pid")
        if ready.get("event") != "ready" or not ready.get("front"):
            return False, f"{name}: capture window did not come to the front: {ready}"
        with tempfile.TemporaryDirectory(dir=os.path.expanduser("~/work/scratch")) as data:
            env = dict(os.environ, LARYNX_CAPTURE_PID=str(cap_pid), LARYNX_DATA_DIR=data, **extra_env)
            feed = subprocess.run([BIN, "listen", "--feed", str(ROOT / "tests/fixtures/report.wav"), "--deliver",
                                   "--mode", "standard", "--models-dir", MODELS], capture_output=True, text=True, env=env, timeout=300)
        result = next((json.loads(l) for l in feed.stdout.splitlines() if '"event":"result"' in l.replace(" ", "")), None)
        if not result:
            return False, f"{name}: no result from listen --feed: {feed.stdout[-300:]} {feed.stderr[-300:]}"
        expected, seen, deadline = expect(result["text"]), "", time.time() + 3
        while time.time() < deadline and expected not in seen:
            texts = [m["text"] for m in map(json.loads, filter(str.strip, out.read_text().splitlines())) if m.get("event") == "text"]
            seen = texts[-1] if texts else ""
            time.sleep(0.05)
        time.sleep(0.8)  # a late duplicate would show up here
        texts = [m["text"] for m in map(json.loads, filter(str.strip, out.read_text().splitlines())) if m.get("event") == "text"]
        seen = texts[-1] if texts else ""
        delivery = result.get("delivery", "")
        ok = seen.strip() == expected.strip() and delivery.startswith(want_delivery)
        return ok, (f"{name}: delivery {delivery!r}, {result.get('deliverMs')} ms; window shows {seen!r}"
                    + ("" if ok else f" (expected {expected!r} once, delivery {want_delivery!r})"))
    finally:
        if cap_pid:
            try: os.kill(cap_pid, 15)
            except ProcessLookupError: pass
        subprocess.run([LSREGISTER, "-u", str(Path(work) / "LarynxCaptureTest.app")], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


def main():
    if os.environ.get("LARYNX_LIVE_OK") != "1":
        sys.exit("live.py pastes into a window it brings to the front: run it as  scripts/when-idle.sh python3 tests/live.py")
    previous = front_bundle()
    lower = lambda t: t[0].lower() + t[1:]
    cases = [("paste, verified", {}, "inserted", "", lambda t: t),
             ("paste never arrives -> fallback inserts once", {"LARYNX_TEST_DROP_PASTE": "1"}, "inserted by", "", lambda t: t),
             ("after a finished sentence: space added", {}, "inserted", "Okay.", lambda t: "Okay. " + t),
             ("mid-sentence: space and lowercase", {}, "inserted", "Hey Sam,", lambda t: "Hey Sam, " + lower(t))]
    failed = 0
    try:
        for name, env, want, prefill, expect in cases:
            ok, line = run_case(name, env, want, prefill, expect)
            print(("PASS " if ok else "FAIL ") + line, flush=True)
            failed += not ok
    finally:
        if previous: subprocess.run(["open", "-b", previous])
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
