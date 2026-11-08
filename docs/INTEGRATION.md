# Integrating Larynx into a host app (Locust)

Larynx runs as a child process. The host owns the UI and the hotkey; Larynx owns the microphone, the speech
model and, if asked, pasting into other apps. No network, no accounts.

## Shipping it

1. Build: `swift build -c release` in this repo, then copy `.build/release/larynx` into the host app's
   resources (for Electron: `extraResource` in Forge, or `extraResources` in electron-builder).
2. Sign it with the host's Developer ID; macOS will attribute the microphone prompt to the host app.
3. The first `ready` takes about 45 s on a new machine while the model downloads (about 500 MB). Show a
   "preparing dictation" state until then. Pass `--models-dir` to keep the model inside the host's data folder.

## Protocol

Spawn `larynx serve [--models-dir <path>]`. Write one JSON object per line to stdin, read one per line from
stdout. stderr is human-readable logging only. Add an `id` to any request; it comes back on the reply.

| Request | Effect | Replies |
| --- | --- | --- |
| `{"cmd":"start"}` | Start recording | `recording`, or `error` if the mic is refused |
| `{"cmd":"stop","mode":"ai","paste":false}` | Stop and transcribe. `mode` is `ai`, `correspondence` or `standard` (default); `verbatim: true` skips the tidy rules; `clean: true` runs the experimental Apple-model pass; `paste` pastes into the focused app | `processing`, then `result` |
| `{"cmd":"cancel"}` | Stop and discard | `cancelled` |
| `{"cmd":"transcribe","path":"/abs/file.m4a"}` | Transcribe a file | `result` |
| `{"cmd":"status"}` | Report state | `status` |
| `{"cmd":"quit"}` | Exit | none |

Events:

```json
{"event":"ready","model":"bark-3.0-clean","cleanup":true,"pasteAllowed":false}
{"event":"result","id":7,"text":"Ship it on Monday.","raw":"Ship it on Monday.","audioSeconds":1.9,"asrMs":41,"totalMs":41}
{"event":"error","id":7,"message":"microphone access was refused"}
```

`result.delivered` (`inserted` or `copied`), `result.pasted` and `result.pasteError` appear only when `paste` was
requested. If pasting is impossible (no Accessibility permission, a password field, any error) the text is left on
the clipboard and `delivered` is `copied`, so a transcript is never lost. `result.engine` says which speech model
produced the text: when the main model returns nothing for a clip that clearly has speech in it, Larynx retries with
the other model if it is already downloaded.

## Two ways to use it in Locust

1. **Dictate into Locust's own composer** (no extra permissions): on hotkey down send `start`, on release
   send `stop`, insert `result.text` into the composer yourself. Only Microphone permission is needed.
2. **Dictate into any app** (later): send `stop` with `"paste":true`. This needs Accessibility permission
   for the host app; check `pasteAllowed` in `ready`/`status` and walk the user to the switch if it is false.

## Minimal Node example

```js
const { spawn } = require('node:child_process');
const readline = require('node:readline');

const larynx = spawn(larynxPath, ['serve', '--models-dir', modelsDir]);
readline.createInterface({ input: larynx.stdout }).on('line', (line) => {
  const msg = JSON.parse(line);
  if (msg.event === 'result') insertIntoComposer(msg.text);
  if (msg.event === 'error') console.warn('larynx:', msg.message);
});
const send = (obj) => larynx.stdin.write(JSON.stringify(obj) + '\n');

onHotkeyDown(() => send({ cmd: 'start' }));
onHotkeyUp(() => send({ cmd: 'stop', mode: 'ai' }));  // Locust's composer talks to AI teammates
app.on('before-quit', () => send({ cmd: 'quit' }));
```

## MCP server for agents

`larynx mcp` speaks the Model Context Protocol over stdio (JSON-RPC 2.0, one message per line), so agents can use
Larynx directly. Tools:

| Tool | Arguments | Returns |
| --- | --- | --- |
| `transcribe_file` | `path`, optional `mode` | The cleaned transcript of an audio file |
| `clean_text` | `text`, optional `mode` (default `correspondence`) | Dictionary, tidy rules and, when needed, the AI rewrite |
| `add_dictionary_word` | `heard`, `written` | Adds an entry to `~/Library/Application Support/Larynx/dictionary.json` |
| `status` | none | Speech model, rewrite availability, dictionary size |

Claude Code:

```bash
claude mcp add larynx -- ~/work/larynx/.build/release/larynx mcp --models-dir "$HOME/Library/Application Support/Larynx/models"
```

## Not yet

- `serve` has no partial text while you speak (the menu bar app shows a live preview); the result arrives on
  `stop` (about 50 ms for a short clip).
- Mic recording through `serve` has been built but not yet tested live; file transcription is tested.
- Apple Silicon and macOS 15 or later only.
