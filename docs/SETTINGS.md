# Larynx settings

Settings live in `~/Library/Application Support/Larynx/settings.json` (the `LARYNX_DATA_DIR`
environment variable moves it, together with history, to another folder; tests use this). The file is
optional; Larynx does not create it merely to read settings. Precedence is:
command-line override (where supported), valid JSON value, legacy `defaults` key,
built-in default. Legacy defaults still work for keys not overridden in JSON.

The service checks file bytes on access. Replacing/editing the file is picked up
on the next dictation, menu read, or settings read; a dictation keeps one stage
policy snapshot throughout processing. Engine and initial talk keys are launch
configuration: restart to apply external file changes to those. Vocabulary roots,
developer terms and vocabulary enablement take effect on Reload Vocabulary or
next launch. Preview, rewrite and learning decisions read their current settings.

Malformed JSON retains the last successfully read JSON object in that process.
At first launch with malformed JSON, legacy/built-in defaults apply. Invalid
individual values fall through to legacy/default values. Deleting the file clears
JSON overrides. Unknown keys are ignored and preserved when the menu writes.
Menu changes are saved atomically to JSON and mirrored to legacy defaults; they
fail visibly in the log rather than replacing a malformed file. Removing a JSON
override allows a later `defaults write` for that key to take effect again.

| Key | Default | Values and meaning |
| --- | --- | --- |
| `engine` | `clean` | `clean` or `parakeet`; speech model, selected at launch; `--engine` overrides it. |
| `rewrite` | `auto` | `auto` or `off`; trigger-based Apple rewrite; `--rewrite` overrides it. `--clean` requests a forced rewrite, unless the rewrite stage is off. |
| `vocabulary` | `on` | `on` or `off`; speech vocabulary boosting; `--vocab` overrides it. |
| `vocabularyRoots` | `~/work` | Comma-separated project root paths; tilde expanded; empty disables project roots. |
| `devTerms` | `on` | `on` or `off`; include the built-in developer term list in vocabulary. |
| `preview` | `on` | `on` or `off`; live preview pill. |
| `pillPosition` | `auto` | `auto` puts the pill just above the text field you are dictating into (when the app says where it is and the field is not a tall document area), else at the bottom of the screen; `bottom` always uses the bottom of the screen. |
| `learn` | `on` | `on` or `off`; watch the field for a correction after insertion. |
| `keys` | `""` | Comma-separated `fn,rightOption,rightCommand,rightControl`; empty means Fn, Right Option, Right Command. `--key` overrides it; menu key changes also update the active listener. |
| `loginItemSet` | `false` | Internal boolean: first-run login-item setup has been attempted. Actual login-item status comes from macOS. |
| `history` | `on` | `on` or `off`; keep dictations in `history.sqlite` on this Mac and spool audio until each is transcribed (crash recovery). `off` keeps Recent in memory only and writes nothing. See [PRIVACY.md](PRIVACY.md). |
| `historyDays` | `30` | Whole days (1-3650) of dictation text to keep; older rows are deleted at launch and after each dictation. A JSON number or string. |
| `keepAudio` | `off` | `off` or whole days (1-365) to keep each dictation's audio in `history/audio/` after it is transcribed. |
| `debugText` | `off` | `on` or `off`; write transcript text into `~/Library/Logs/Larynx.log` (for debugging only). Off logs timing, app, delivery and word counts. |
| `stages.snippet` | `on` | `off`, `shadow`, `on`; whole-utterance snippet matching. |
| `stages.dictionary` | `on` | `off`, `shadow`, `on`; personal dictionary replacements. |
| `stages.vocabularyCase` | `on` | `off`, `shadow`, `on`; distinctive vocabulary spelling/case. |
| `stages.tidy` | `on` | `off`, `shadow`, `on`; deterministic cleanup rules. |
| `stages.rewrite` | `on` | `off`, `shadow`, `on`; Apple-model rewrite, still gated by `rewrite`, mode, and rewrite triggers. |

`stages.*` keys are nested inside a JSON `stages` object. The corresponding
legacy defaults keys use the dotted names shown in the table. Example:

```json
{
  "preview": "on",
  "rewrite": "auto",
  "stages": {
    "dictionary": "shadow",
    "rewrite": "off"
  }
}
```

The stage order is snippet → dictionary → vocabularyCase → tidy → rewrite.
`on` runs and applies a stage; `off` skips it; `shadow` computes a candidate and
records a Step without feeding the candidate to subsequent stages or delivery.
Each reached stage records `stage`, `before`, `after`, `applied`. `applied` means
the stage ran in `on` mode, including an identity transformation. Skipped stages
have identical before/after and `applied: false`. A matched `on` snippet ends the
pipeline immediately so its literal saved text cannot be changed. A shadow
snippet records its proposed expansion and continues using the original words.

`--verbatim` (or serve's `verbatim`) disables the first four stages, as before;
rewrite remains separately controlled, as before. CLI `tidy` and `rewrite` are
component diagnostics: they directly exercise those components for reproducible
tests. File transcription, listen and serve run the complete pipeline. MCP's
`clean_text` uses the same pipeline with no snippet map or speech vocabulary,
preserving its original dictionary → tidy → rewrite behavior.

The five existing stages remain on by default because this refactor preserves
already-shipped behavior. New text-changing stages must default to shadow mode
and pass the master plan's review gate before enabling them. Task 0.7 will persist
shadow proposals in History and expose review tools; this task records them in
the returned Transcript only. Future settings are added to `Settings.Key` and
this table as their features are implemented; a test checks all registered keys
and defaults are documented.
