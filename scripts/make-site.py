#!/usr/bin/env python3
"""Build the landing page (PLAN-launch L0.10): site/template.html -> site/index.html.

    python3 scripts/make-site.py           # write site/index.html
    python3 scripts/make-site.py --check   # fail if index.html is out of date with the template or the numbers

Every number on the page is read from the README or docs/BENCHMARKS.md, so the page and the README cannot drift:
change a number there, run this, and the page follows. If a number can't be found, this fails instead of guessing.
GitHub Pages serves the site/ folder (.github/workflows/pages.yml).
"""
import re, sys, urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = "https://larynx.locust.lol/"
REPO = "https://github.com/StopBanning/larynx"


def find(pattern, text, what):
    m = re.search(pattern, text, re.S)
    if not m:
        sys.exit(f"make-site: could not find {what} (pattern {pattern!r}); the page would be wrong, so nothing was written")
    return m.group(1)


def numbers():
    readme = (ROOT / "README.md").read_text()
    bench = (ROOT / "docs/BENCHMARKS.md").read_text()
    random_set = find(r"## Real voice, picked at random(.*?)(?:\n## |\Z)", bench, "the random-dictation section of BENCHMARKS.md")
    return {
        "SPEED": find(r"<b>([\d.]+) s</b> from letting go", readme, "the speed in the README"),
        "MODEL_MB": find(r"speech model \(about (\d+) MB\)", readme, "the model size in the README"),
        "INSTALL": find(r"```bash\n(curl -fsSL \S+/install\.sh \| zsh)\n```", readme, "the install line in the README"),
        "TESTS": find(r"\| `swift test` \| (\d+) tests", readme, "the Swift test count in the README"),
        "WER": find(r"\n\| ultra \| ([\d.]+%) \|", random_set, "Ultra's WER on the random set"),
        "WER_CLIPS": find(r"This set is (\d+) dictations", random_set, "the size of the random set"),
        "SITE": SITE,
        "SITE_ENC": urllib.parse.quote(SITE, safe=""),
        "REPO": REPO,
    }


def render():
    template = (ROOT / "site/template.html").read_text()
    values = numbers()
    missing = sorted(set(re.findall(r"\{\{(\w+)\}\}", template)) - set(values))
    if missing:
        sys.exit(f"make-site: the template uses {missing}, which this script doesn't fill")
    return re.sub(r"\{\{(\w+)\}\}", lambda m: values[m.group(1)], template)


def main():
    out = ROOT / "site/index.html"
    html = render()
    if "--check" in sys.argv:
        if not out.exists() or out.read_text() != html:
            sys.exit("site/index.html is out of date: run python3 scripts/make-site.py")
        print("site/index.html is up to date")
        return
    out.write_text(html)
    print(f"wrote {out.relative_to(ROOT)} ({len(html.encode()) // 1024} KB)")


if __name__ == "__main__":
    main()
