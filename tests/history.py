#!/usr/bin/env python3
"""Crash-recovery gate (master plan 0.6), file-only: no microphone, key presses or pasting.

1. `listen --feed` spools the fixture, then is killed with SIGKILL while "transcribing" (LARYNX_TEST_DELAY_MS).
2. The spool must still hold the recording; `recover` (what the app runs at launch) must turn it into a
   history row flagged "recovered" with the right text, and empty the spool.
3. A normal feed must save a row and leave the spool empty; `history --search` must find it.
4. `history: off` must write nothing at all.
Uses a throwaway data folder (LARYNX_DATA_DIR), never the real history.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default=str(ROOT / '.build/release/larynx'))
parser.add_argument('--models-dir', default=str(Path.home() / 'Library/Application Support/Larynx/models'))
a = parser.parse_args()
fixture = ROOT / 'tests/fixtures/report.wav'
expected = 'Please send the report tomorrow.'
common = ['--engine', 'clean', '--rewrite', 'off', '--vocab', 'off', '--models-dir', a.models_dir]
data = Path(tempfile.mkdtemp(prefix='larynx-history-gate-'))


def env(**extra):
    e = dict(os.environ, LARYNX_DATA_DIR=str(data))
    e.update(extra)
    return e


def run(*args, **extra):
    p = subprocess.run([a.binary, *args, *common], capture_output=True, text=True, timeout=240, env=env(**extra))
    assert p.returncode == 0, (args, p.returncode, p.stderr[-2000:])
    return p.stdout


def spool():
    d = data / 'history/spool'
    return sorted(x.name for x in d.iterdir()) if d.exists() else []


try:
    # 1. Kill mid-dictation.
    p = subprocess.Popen([a.binary, 'listen', '--feed', str(fixture), *common], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, env=env(LARYNX_TEST_DELAY_MS='60000'))
    first = json.loads(p.stdout.readline())
    assert first['event'] == 'spooled' and first['saved'], first
    time.sleep(0.5)
    p.send_signal(signal.SIGKILL)
    p.wait(timeout=10)
    assert spool() == [first['id'] + '.json', first['id'] + '.wav'], spool()
    time.sleep(1.1)  # recovery only takes spool files older than its own launch

    # 2. Next launch recovers it.
    rows = json.loads(run('recover', '--json'))
    assert len(rows) == 1, rows
    row = rows[0]
    assert row['id'] == first['id'] and 'recovered' in row['flags'] and row['delivery'] == 'recovered', row
    assert row['text'] == expected, row['text']
    assert spool() == [], spool()
    assert json.loads(run('recover', '--json')) == [], 'recovered twice'

    # 3. A normal dictation is saved and searchable; the spool is cleared.
    out = [json.loads(line) for line in run('listen', '--feed', str(fixture)).splitlines()]
    assert out[-1]['event'] == 'result' and out[-1]['text'] == expected, out
    assert spool() == [], spool()
    found = json.loads(run('history', '--search', 'repo', '--json'))
    assert [r['id'] for r in found] == [out[-1]['id'], first['id']], found
    assert all(r['steps'] for r in found), 'steps not stored'

    # 4. history: off writes nothing.
    off = Path(tempfile.mkdtemp(prefix='larynx-history-off-'))
    try:
        (off / 'settings.json').write_text('{"history": "off"}')
        p = subprocess.run([a.binary, 'listen', '--feed', str(fixture), *common], capture_output=True, text=True,
                           timeout=240, env=dict(os.environ, LARYNX_DATA_DIR=str(off)))
        assert p.returncode == 0, p.stderr[-2000:]
        result = [json.loads(line) for line in p.stdout.splitlines()]
        assert result[0]['saved'] is False and result[-1]['text'] == expected, result
        assert sorted(x.name for x in off.iterdir()) == ['settings.json'], list(off.iterdir())
    finally:
        shutil.rmtree(off, ignore_errors=True)

    print(f'PASS: killed mid-dictation, recovered "{row["text"]}" as {row["id"]}; normal dictation saved and '
          'searchable; spool empty afterwards; history off wrote nothing')
finally:
    shutil.rmtree(data, ignore_errors=True)
