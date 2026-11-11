#!/usr/bin/env python3
"""File-only serve/MCP compatibility smoke; uses downloaded models, never mic or paste."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default=str(ROOT / '.build/release/larynx'))
parser.add_argument('--models-dir', default=str(Path.home() / 'Library/Application Support/Larynx/models'))
a = parser.parse_args()
fixture = ROOT / 'tests/fixtures/report.wav'
legacy = json.loads((ROOT / 'tests/fixtures/serve-before-transcript.json').read_text())
args = ['--engine', 'clean', '--rewrite', 'off', '--vocab', 'off', '--models-dir', a.models_dir]


def run(command, messages):
    p = subprocess.run([a.binary, command, *args],
                       input=''.join(json.dumps(m) + '\n' for m in messages),
                       capture_output=True, text=True, timeout=180)
    assert p.returncode == 0, (command, p.returncode, p.stderr[-2000:])
    return [json.loads(line) for line in p.stdout.splitlines()]


def check_transcript(actual):
    for key, value in legacy.items():
        if key in {'event', 'id'}:
            continue
        assert key in actual, f'Missing legacy field: {key}'
        if key in {'asrMs', 'totalMs'}:
            assert type(actual[key]) is int and actual[key] >= 0, (key, actual[key])
        else:
            assert type(actual[key]) is type(value), (key, actual[key], value)
            assert actual[key] == value, (key, actual[key], value)
    assert isinstance(actual['steps'], list)


rows = run('serve', [
    {'id': 'fixture', 'cmd': 'transcribe', 'path': str(fixture), 'mode': 'standard'},
    {'id': 42, 'cmd': 'transcribe', 'path': str(fixture), 'mode': 'standard', 'verbatim': True},
    {'id': 'status', 'cmd': 'status'},
    {'cmd': 'quit'},
])
result = next(r for r in rows if r.get('id') == 'fixture' and r.get('event') == 'result')
check_transcript(result)
verbatim = next(r for r in rows if r.get('id') == 42 and r.get('event') == 'result')
assert verbatim['text'] == verbatim['raw']
assert next(r for r in rows if r.get('id') == 'status')['event'] == 'status'

rows = run('mcp', [
    {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {
        'name': 'transcribe_file', 'arguments': {'path': str(fixture), 'mode': 'standard'}}},
])
assert rows[0]['result']['protocolVersion'] == '2025-06-18'
body = next(r for r in rows if r.get('id') == 2)['result']
assert body['isError'] is False
assert body['content'] == [{'type': 'text', 'text': legacy['text']}]
check_transcript(body['structuredContent'])

p = subprocess.run([a.binary, 'transcribe', str(fixture), *args], capture_output=True, text=True, timeout=180)
assert p.returncode == 0 and p.stdout.strip() == legacy['text'], p.stderr[-2000:]
print('PASS: serve legacy fields, string/integer request IDs, verbatim, status, MCP text + structured result, CLI transcription')
print('Fixture text:', legacy['text'])
