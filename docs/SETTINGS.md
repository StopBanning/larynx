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
| `engine` | `ultra` | Speech model, selected at launch; `--engine` overrides it. `ultra` (Parakeet Ultra, 25 languages, the most accurate in docs/BENCHMARKS.md), `clean` (Bark 3.0 Clean, English, drops ums as it listens; the default before v0.5), `parakeet` (Parakeet TDT v3, 25 languages), and benchmark candidates `bark3` (verbatim Bark) and `unified` (Parakeet Unified, English with built-in punctuation). |
| `rewrite` | `auto` | `auto` or `off`; trigger-based Apple rewrite; `--rewrite` overrides it. `--clean` requests a forced rewrite, unless the rewrite stage is off. |
| `vocabulary` | `on` | `on` or `off`; speech vocabulary boosting; `--vocab` overrides it. |
| `vocabularyRoots` | `~/work` | Comma-separated project root paths; tilde expanded; empty disables project roots. |
| `devTerms` | `on` | `on` or `off`; include the built-in developer term list in vocabulary. |
| `preview` | `on` | `on` or `off`; live preview pill. |
| `pillPosition` | `auto` | `auto` puts the pill just above the text field you are dictating into (when the app says where it is and the field is not a tall document area), else at the bottom of the screen; `bottom` always uses the bottom of the screen. |
| `pillGlass` | `25` | 0-100: how see-through the pill is. 0 is no glass at all (the icon, waveform and words float over the window), 25 is clear Liquid Glass, 50 is frosted, 100 is solid. The Glass slider in the menu sets it and shows the pill while you drag. |
| `doubtHint` | `on` | `on` or `off`. When the speech model was very unsure of a word (or wrote a word no dictionary knows), the pill says "Not sure about “…”" for 2 seconds after the paste and the dictation is flagged `doubtful` in history. Nothing in the text is changed. |
| `micWarm` | `30` | 0-300 seconds the microphone stays open after a dictation, so the next press starts instantly and includes the 0.15 s before it (a cold start takes 150-300 ms and can lose the first syllable). While open, audio only passes through a 0.15 s buffer in memory and is never kept; macOS shows its microphone indicator. `0` closes it after every dictation. |
| `verifyPaste` | `on` | `on` or `off`. Where the text field can be read, check the paste arrived; if the field is unchanged after 0.6 s, insert the words through Accessibility, then by typing, then leave them on the clipboard. A field that changed or can't be read is left alone, so words are never inserted twice. |
| `fitToField` | `on` | `on` or `off`. Where the text field can be read, fit the dictation to the text before the cursor: add the missing space after the previous sentence ("time. Are we"), and lowercase a first word that was only capitalized as a sentence start when you're mid-sentence ("Hey Sam, can you"). Names, "I", acronyms and your vocabulary keep their capitals; empty fields, new lines and selections are left alone. |
| `learn` | `on` | `on` or `off`; watch the field for a correction after insertion. |
| `keys` | `""` | Comma-separated `fn,rightOption,rightCommand,rightControl`; empty means Fn, Right Option, Right Command. `--key` overrides it; menu key changes also update the active listener. |
| `handsFree` | `on` | `on` or `off`; double-tap a talk key to keep recording with no key held. The next press of a talk key finishes, Esc cancels, and it stops by itself after 30 minutes. |
| `toggleKeys` | `""` | Comma-separated keys (same names as `keys`) that start hands-free with one press and finish it with the next: map a second macro-pad button to one, for example `rightControl`. |
| `loginItemSet` | `false` | Internal boolean: first-run login-item setup has been attempted. Actual login-item status comes from macOS. |
| `history` | `on` | `on` or `off`; keep dictations in `history.sqlite` on this Mac and spool audio until each is transcribed (crash recovery). `off` keeps Recent in memory only and writes nothing. See [PRIVACY.md](PRIVACY.md). |
| `historyDays` | `30` | Whole days (1-3650) of dictation text to keep; older rows are deleted at launch and after each dictation. A JSON number or string. |
| `keepAudio` | `off` | `off` or whole days (1-365) to keep each dictation's audio in `history/audio/` after it is transcribed (16-bit FLAC, about 1 MB per minute of speech). |
| `debugText` | `off` | `on` or `off`; write transcript text into `~/Library/Logs/Larynx.log` (for debugging only). Off logs timing, app, delivery and word counts. |
| `stages.snippet` | `on` | `off`, `shadow`, `on`; whole-utterance snippet matching. |
| `stages.dictionary` | `on` | `off`, `shadow`, `on`; personal dictionary replacements. |
| `stages.vocabularyCase` | `on` | `off`, `shadow`, `on`; distinctive vocabulary spelling/case. |
| `stages.tidy` | `on` | `off`, `shadow`, `on`; deterministic cleanup rules. |
| `stages.numbers` | `on` | `off`, `shadow`, `on`; spoken numbers to digits ("ninety-four" -> 94, "five point two" -> 5.2, "three percent" -> 3%), in every mode. Small numbers stay words unless a unit or label follows ("3%", "step 2"). |
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

The stage order is snippet → dictionary → vocabularyCase → tidy → numbers → rewrite.
`on` runs and applies a stage; `off` skips it; `shadow` computes a candidate and
records a Step without feeding the candidate to subsequent stages or delivery.
`larynx mine --shadow` counts what each shadowed stage would have changed in your history;
`larynx mine --shadow <stage>` lists them (before and after).

Shadow rules are the same idea for a single new cleanup rule: they run after tidy on every dictation and record a
`shadow:<name>` step, but never change the text. `larynx mine --shadow lone-letter` lists one; `larynx tidy
--shadow "<text>"` shows what each would do. A rule is moved into the live rules only after its proposals on real
dictations have been read. Current shadow rules: `lone-letter` (drops a cut-off letter: "someone who f will
actually fix it" → "someone who will actually fix it").
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
