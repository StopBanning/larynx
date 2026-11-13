#!/usr/bin/env python3
"""Metrics script test (L0.12): counts come out right and running it twice never counts a day twice.

    python3 tests/metrics.py

Offline: feeds scripts/metrics.py made-up GitHub replies and writes to a throwaway folder.
"""
import importlib.util, shutil, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("metrics", ROOT / "scripts/metrics.py")
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
failures = []


def check(ok, what):
    print(f"{'ok ' if ok else 'FAIL'} {what}")
    if not ok: failures.append(what)


def reply(views, clones):
    return {
        "repo": {"stargazers_count": 12, "forks_count": 2, "subscribers_count": 3, "open_issues_count": 1},
        "views": {"count": sum(v for _, v, _ in views), "uniques": 5,
                  "views": [{"timestamp": f"{d}T00:00:00Z", "count": v, "uniques": u} for d, v, u in views]},
        "clones": {"count": sum(c for _, c, _ in clones), "uniques": 2,
                   "clones": [{"timestamp": f"{d}T00:00:00Z", "count": c, "uniques": u} for d, c, u in clones]},
        "referrers": [{"referrer": "news.ycombinator.com", "count": 9, "uniques": 7},
                      {"referrer": "github.com", "count": 3, "uniques": 1}],
        "releases": [{"tag_name": "v0.6.0", "assets": [{"download_count": 4}, {"download_count": 1}]},
                     {"tag_name": "v0.5.0", "assets": [{"download_count": 2}]}],
    }


scratch = Path.home() / "work/scratch"
scratch.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix="larynx-metrics-", dir=scratch))
try:
    first = reply([("2026-11-01", 4, 2), ("2026-11-02", 6, 3)], [("2026-11-02", 1, 1)])
    row = metrics.save(out, first, datetime(2026, 11, 2, tzinfo=timezone.utc))
    check(row["downloads"] == 7 and row["downloads_by_release"] == "v0.6.0:5;v0.5.0:2", "release downloads add up")
    check(row["referrers_14d"] == "news.ycombinator.com:9;github.com:3", "referrers kept in order")
    check(row["views_14d"] == 10 and row["stars"] == 12, "views and stars")

    # A week later GitHub still reports Nov 2 (now complete, with more views) and adds Nov 9.
    second = reply([("2026-11-02", 8, 4), ("2026-11-09", 5, 5)], [("2026-11-09", 2, 1)])
    metrics.save(out, second, datetime(2026, 11, 9, tzinfo=timezone.utc))
    metrics.save(out, second, datetime(2026, 11, 9, tzinfo=timezone.utc))  # run twice the same day
    days = {r["day"]: r for r in metrics.read_csv(out / "traffic-daily.csv")}
    check(sorted(days) == ["2026-11-01", "2026-11-02", "2026-11-09"], "each day saved once, old days kept")
    check(days["2026-11-02"]["views"] == "8" and days["2026-11-01"]["views"] == "4", "a day still reported takes the newer count")
    check(days["2026-11-01"]["clones"] == "0" and days["2026-11-09"]["cloners"] == "1", "a day with no clones reads 0")
    runs = metrics.read_csv(out / "metrics.csv")
    check([r["date"] for r in runs] == ["2026-11-02", "2026-11-09"], "one run row per day")
finally:
    shutil.rmtree(out, ignore_errors=True)
sys.exit(1 if failures else 0)
