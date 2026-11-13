#!/usr/bin/env python3
"""Count how Larynx is doing from GitHub's public numbers, with no telemetry (PLAN-launch L0.12).

    python3 scripts/metrics.py [--repo owner/name] [--out ~/work/larynx-launch]

The app never reports anything. This reads what GitHub already keeps about the repository, through the `gh`
command (you must be signed in with push access to see traffic). GitHub forgets traffic after 14 days, so run it
at least every two weeks; weekly is the plan. Running it more often is harmless: days are merged, never counted twice.

Writes two files in --out:
- metrics.csv: one row per run. Stars, forks, watchers, open issues, release downloads (total and per release),
  the 14-day views, unique visitors, clones and the top referrers.
- traffic-daily.csv: one row per day with views, unique visitors, clones and unique cloners. A day GitHub still
  reports replaces the saved one (the newest numbers are the complete ones).
"""
import argparse, csv, json, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

RUN_FIELDS = ["date", "stars", "forks", "watchers", "open_issues", "downloads", "downloads_by_release",
              "views_14d", "visitors_14d", "clones_14d", "cloners_14d", "referrers_14d"]
DAY_FIELDS = ["day", "views", "visitors", "clones", "cloners"]


def gh(path):
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"gh api {path} failed: {out.stderr.strip()}")
    return json.loads(out.stdout)


def fetch(repo):
    """Everything this script reads, in one dict, so the rest can be tested without the network."""
    return {
        "repo": gh(f"repos/{repo}"),
        "views": gh(f"repos/{repo}/traffic/views"),
        "clones": gh(f"repos/{repo}/traffic/clones"),
        "referrers": gh(f"repos/{repo}/traffic/popular/referrers"),
        "releases": gh(f"repos/{repo}/releases?per_page=100"),
    }


def run_row(data, now):
    releases = data["releases"]
    per_release = {r.get("tag_name") or r.get("name") or "?": sum(a.get("download_count", 0) for a in r.get("assets", []))
                   for r in releases}
    repo = data["repo"]
    return {
        "date": now.strftime("%Y-%m-%d"),
        "stars": repo.get("stargazers_count", 0),
        "forks": repo.get("forks_count", 0),
        "watchers": repo.get("subscribers_count", 0),
        "open_issues": repo.get("open_issues_count", 0),  # GitHub counts open pull requests here too
        "downloads": sum(per_release.values()),
        "downloads_by_release": ";".join(f"{tag}:{n}" for tag, n in per_release.items()),
        "views_14d": data["views"].get("count", 0),
        "visitors_14d": data["views"].get("uniques", 0),
        "clones_14d": data["clones"].get("count", 0),
        "cloners_14d": data["clones"].get("uniques", 0),
        "referrers_14d": ";".join(f"{r['referrer']}:{r['count']}" for r in data["referrers"]),
    }


def merge_days(saved, data):
    """Saved day rows plus GitHub's, keyed by day; GitHub's numbers win for any day it still reports."""
    days = {row["day"]: row for row in saved}
    fresh = {}
    for kind, count, uniques in (("views", "views", "visitors"), ("clones", "clones", "cloners")):
        for d in data[kind].get(kind, []):
            row = fresh.setdefault(d["timestamp"][:10], {"day": d["timestamp"][:10]})
            row[count], row[uniques] = d.get("count", 0), d.get("uniques", 0)
    for day, row in fresh.items():
        days[day] = {f: row.get(f, 0) for f in DAY_FIELDS}
    return [days[d] for d in sorted(days)]


def read_csv(path):
    if not path.exists():
        return []
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def write_csv(path, fields, rows):
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    tmp.replace(path)


def save(out, data, now):
    out.mkdir(parents=True, exist_ok=True)
    row = run_row(data, now)
    runs = [r for r in read_csv(out / "metrics.csv") if r["date"] != row["date"]] + [row]  # one row per day
    write_csv(out / "metrics.csv", RUN_FIELDS, runs)
    write_csv(out / "traffic-daily.csv", DAY_FIELDS, merge_days(read_csv(out / "traffic-daily.csv"), data))
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default="StopBanning/larynx")
    ap.add_argument("--out", default=str(Path.home() / "work/larynx-launch"))
    a = ap.parse_args()
    row = save(Path(a.out).expanduser(), fetch(a.repo), datetime.now(timezone.utc))
    print(f"{row['date']}: {row['stars']} stars, {row['downloads']} downloads, "
          f"{row['views_14d']} views from {row['visitors_14d']} visitors in 14 days, {row['clones_14d']} clones. "
          f"Saved to {a.out}")


if __name__ == "__main__":
    main()
