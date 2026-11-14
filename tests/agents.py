#!/usr/bin/env python3
"""Agents test (L0.11): the examples in docs/AGENTS.md do what the page says.

    python3 tests/agents.py [--binary path]

Talks to `larynx mcp` the way an agent does (initialize, tools/list, tools/call) and runs `larynx tidy`, all
with a throwaway data folder (LARYNX_DATA_DIR), and checks that your real dictionary is not touched. No speech
model is loaded and no microphone is used, so it runs in a second; `tests/protocol.py` covers transcribing a file
through MCP.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REAL_DICTIONARY = Path.home() / "Library/Application Support/Larynx/dictionary.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=str(ROOT / ".build/release/larynx"))
    binary = ap.parse_args().binary
    failures = []

    def check(ok, what):
        print(f"{'ok ' if ok else 'FAIL'} {what}")
        if not ok: failures.append(what)

    scratch = Path.home() / "work/scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    data = Path(tempfile.mkdtemp(prefix="larynx-agents-", dir=scratch))
    before = REAL_DICTIONARY.stat().st_mtime_ns if REAL_DICTIONARY.exists() else None
    env = dict(os.environ, LARYNX_DATA_DIR=str(data))
    try:
        def tidy(*args):
            return subprocess.run([binary, "tidy", *args], env=env, capture_output=True, text=True, timeout=30).stdout.strip()

        said = "um so can you uh refactor the the login function so it it returns early"
        check(tidy("--mode", "ai", said) == "So can you refactor the login function so it returns early",
              "tidy --mode ai: fillers and doubled words out, no period added")
        check(tidy("--mode", "correspondence", said).endswith("returns early."), "tidy --mode correspondence ends with a period")

        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": {"name": "clean_text", "arguments": {"text": "um the the deploy is uh broken again", "mode": "ai"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
             "params": {"name": "add_dictionary_word", "arguments": {"heard": "cube control", "written": "kubectl"}}},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
             "params": {"name": "clean_text", "arguments": {"text": "run cube control get pods", "mode": "ai"}}},
            {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
             "params": {"name": "clean_text", "arguments": {"text": "yeah so we're gonna ship it friday, you know", "style": "professional"}}},
        ]
        out = subprocess.run([binary, "mcp"], input="".join(json.dumps(m) + "\n" for m in messages), env=env,
                             capture_output=True, text=True, timeout=60).stdout
        replies = {m["id"]: m.get("result", {}) for m in map(json.loads, out.splitlines())}
        text = lambda i: (replies.get(i, {}).get("content") or [{}])[0].get("text")

        check(replies.get(1, {}).get("serverInfo", {}).get("name") == "larynx", "initialize answers as larynx")
        check(sorted(t["name"] for t in replies.get(2, {}).get("tools", [])) ==
              ["add_dictionary_word", "clean_text", "status", "transcribe_file"], "tools/list has the four tools")
        check(text(3) == "The deploy is broken again", "clean_text in ai mode")
        check((data / "dictionary.json").exists() and json.loads((data / "dictionary.json").read_text()).get("cube control") == "kubectl",
              "add_dictionary_word writes to the data folder")
        check(text(5) == "Run kubectl get pods", "the new word is used straight away")
        check(text(6) == "We're going to ship it Friday.", "clean_text with the professional style")
        # The rules alone, with no AI rewrite after them: what a Mac without Apple Intelligence, or a coding app, gets.
        check(tidy("--mode", "correspondence", "--style", "professional", "yeah so we're gonna ship it friday, you know")
              == "We're going to ship it Friday.", "tidy --style professional, rules only")
        after = REAL_DICTIONARY.stat().st_mtime_ns if REAL_DICTIONARY.exists() else None
        check(before == after, "your real dictionary was not touched")
    finally:
        shutil.rmtree(data, ignore_errors=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
