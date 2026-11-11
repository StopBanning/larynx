#!/usr/bin/env python3
"""Generate the portable fallback from an extracted SCOWL 2020.12.07 release.

Download https://downloads.sourceforge.net/wordlist/scowl-2020.12.07.tar.gz,
extract it outside the repo, then pass the extracted directory as the sole argument.
"""
import hashlib
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
source = Path(sys.argv[1])
files = sorted(p for p in (source / "final").iterdir()
               if p.name.startswith(("english-words.", "american-words.",
                                     "english-contractions.", "american-contractions."))
               and int(p.suffix[1:]) <= 40)
words = sorted({w.lower() for p in files for w in p.read_text(encoding="latin1").splitlines()})
assert len(words) == 56372, f"Wrong source release or selection: {len(words)} entries"
out = ROOT / "Sources/LarynxText/Resources"
(out / "english.txt").write_text("\n".join(words) + "\n", encoding="utf-8")
(out / "SCOWL-Copyright.txt").write_bytes((source / "Copyright").read_bytes())
print("Inputs:", ", ".join(p.name for p in files))
print("Entries:", len(words))
print("SHA256:", hashlib.sha256((out / "english.txt").read_bytes()).hexdigest())
