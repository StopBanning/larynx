#!/usr/bin/env python3
"""Privacy proof (R7): Larynx turns speech into text with every network connection denied.

    python3 tests/privacy.py            # transcribe, one serve request and listen --feed, all with no network
    python3 tests/privacy.py --prove    # also shows the sandbox really blocks: a deliberate network call must fail

Each command runs under a macOS sandbox profile that denies all network access (sandbox-exec), with the speech
models already on disk and a throwaway data folder, so nothing touches your history. A command that tried to reach
the network would get an error and the test would fail. Loading a model compiles it for the Neural Engine the
first time this binary runs it (one to three minutes), so run it when the Mac is otherwise idle:
scripts/when-idle.sh python3 tests/privacy.py
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = os.environ.get("LARYNX_BIN", str(ROOT / ".build/release/larynx"))
MODELS = os.environ.get("LARYNX_MODELS", str(Path.home() / "Library/Application Support/Larynx/models"))
CLIP = str(ROOT / "tests/fixtures/report.wav")
PROFILE = "(version 1)\n(allow default)\n(deny network*)\n"


def sandboxed(cmd, data, stdin=None, timeout=600):
    with tempfile.NamedTemporaryFile("w", suffix=".sb", delete=False) as f:
        f.write(PROFILE)
    env = dict(os.environ, LARYNX_DATA_DIR=data, LARYNX_FORCE_COPY="1")
    try:
        return subprocess.run(["sandbox-exec", "-f", f.name] + cmd, input=stdin, capture_output=True, text=True,
                              env=env, timeout=timeout)
    finally:
        os.unlink(f.name)


def main():
    if not any(p.suffix == ".mlmodelc" for p in Path(MODELS).glob("*/*")):
        print(f"no speech model in {MODELS}; this test needs one already on disk"); sys.exit(2)
    failures = []
    with tempfile.TemporaryDirectory(prefix="larynx-privacy-") as data:
        common = ["--models-dir", MODELS, "--rewrite", "off"]

        r = sandboxed([BIN, "transcribe", CLIP] + common, data)
        ok = r.returncode == 0 and r.stdout.strip() != ""
        print(f"{'ok ' if ok else 'FAIL'} transcribe with no network")
        if not ok: failures.append(("transcribe", r))

        req = json.dumps({"cmd": "transcribe", "path": CLIP, "id": 1}) + "\n" + '{"cmd":"quit"}\n'
        r = sandboxed([BIN, "serve"] + common, data, stdin=req)
        results = [json.loads(l) for l in r.stdout.splitlines() if l.startswith("{")]
        ok = any(m.get("event") == "result" and m.get("text") for m in results)
        print(f"{'ok ' if ok else 'FAIL'} serve request with no network")
        if not ok: failures.append(("serve", r))

        r = sandboxed([BIN, "listen", "--feed", CLIP] + common, data)
        events = [json.loads(l) for l in r.stdout.splitlines() if l.startswith("{")]
        ok = r.returncode == 0 and any(m.get("text") for m in events)
        print(f"{'ok ' if ok else 'FAIL'} listen --feed with no network")
        if not ok: failures.append(("listen --feed", r))

        if "--prove" in sys.argv:
            # The same profile around a program that does reach out: it has to fail, or the test proves nothing.
            probe = [sys.executable, "-I", "-c", "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)"]
            r = sandboxed(probe, data, timeout=30)
            ok = r.returncode != 0
            print(f"{'ok ' if ok else 'FAIL'} a deliberate network call is blocked ({(r.stderr.strip().splitlines() or ['no error'])[-1][:80]})")
            if not ok: failures.append(("probe", r))

    for name, r in failures:
        print(f"\n--- {name} (exit {r.returncode})\n{r.stderr[-1500:]}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
