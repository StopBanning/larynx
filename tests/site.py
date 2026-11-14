#!/usr/bin/env python3
"""Landing page test (L0.10): the page matches the README's numbers, stays light, and every link it makes
into the repository points at a file that exists.

    python3 tests/site.py
"""
import re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
failures = []


def check(ok, what):
    print(f"{'ok ' if ok else 'FAIL'} {what}")
    if not ok: failures.append(what)


r = subprocess.run([sys.executable, str(ROOT / "scripts/make-site.py"), "--check"], capture_output=True, text=True)
check(r.returncode == 0, "index.html is built from the template and the README's current numbers")

html = (SITE / "index.html").read_text()
check("{{" not in html, "no unfilled placeholders")

# What a phone downloads to show the first screen: the page, the icon and the phone-sized sky.
first_load = sum((SITE / f).stat().st_size for f in ("index.html", "icon.png", "sky-1200.jpg"))
check(first_load < 300_000, f"first load is under 300 KB ({first_load // 1024} KB)")

local = set(re.findall(r'(?:src|href|poster)="([^":#?]+)"', html)) - {""}
check(all((SITE / f).exists() for f in local), f"every file the page loads is in site/ ({', '.join(sorted(local))})")

repo_links = set(re.findall(r'github\.com/StopBanning/larynx/blob/main/([^"#]+)', html))
missing = [p for p in repo_links if not (ROOT / p).exists()]
check(not missing and len(repo_links) >= 3, f"links into the repo point at real files ({len(repo_links)} checked){' missing: ' + str(missing) if missing else ''}")

for proof in ("bench/latency.py", "docs/BENCHMARKS.md", "tests/privacy.py"):
    check(proof in repo_links, f"a proof links to {proof}")
check('id="send"' in html and "navigator.share" in html, "phones get the Send this to my Mac button")
sys.exit(1 if failures else 0)
