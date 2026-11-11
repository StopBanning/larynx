# Privacy

Larynx runs entirely on your Mac. After the speech models download (once, from Hugging Face), dictation opens no
network connections: audio, transcripts, your dictionary and history never leave the machine. There are no accounts,
no analytics and no telemetry.

## What is stored, and where

Everything lives under `~/Library/Application Support/Larynx/` unless noted. Folders are created readable by your
user account only.

| What | File | Kept | Turn off |
| --- | --- | --- | --- |
| Dictation text, with the app it went to, timings and the cleanup steps | `history.sqlite` | 30 days (`historyDays`) | `history: off` |
| Audio of a dictation while it is being transcribed (crash spool) | `history/spool/<id>.wav` | Until the transcript is saved, normally well under a second | `history: off` |
| Audio after transcription | `history/audio/<id>.wav` | Not kept unless you set `keepAudio` to a number of days | `keepAudio: off` (default) |
| Your words | `dictionary.json`, `vocabulary.txt`, `snippets.json` | Until you edit them | - |
| Settings | `settings.json` (and the `com.automatedworkflow.larynx` defaults) | - | - |
| Log | `~/Library/Logs/Larynx.log` | Grows until you delete it | Transcript text is not logged unless `debugText: on` |

Settings are described in [SETTINGS.md](SETTINGS.md). `larynx history` prints and searches what is kept.

## Never stored

- Anything dictated while a password field has focus (macOS Secure Input is on, or the focused field is a secure
  text field): no audio spool, no history row.
- Anything dictated into a password manager or keychain app. The built-in list covers Keychain Access, Passwords,
  1Password, Bitwarden, Dashlane, LastPass, Enpass, KeePassXC and Proton Pass. Add bundle ids in `privacy.json`
  (a JSON array, for example `["com.example.vault"]`).
- With `history: off`: nothing at all. Recent then lives in memory and disappears when Larynx quits. The trade-off is
  that a crash during transcription loses that dictation.

## Crash recovery

When `history` is on, a finished recording is written to the spool before transcription starts. If Larynx quits or
crashes before the transcript is saved, the next launch transcribes the spooled audio, saves it as a recovered
dictation (marked "Recovered" in the Recent menu and `[recovered]` in `larynx history`) and deletes the audio.
`larynx recover` does the same from the command line. A spool file that cannot be read is renamed `.unreadable`
rather than deleted, so nothing is thrown away silently.

## Deleting your data

Quit Larynx, then delete `history.sqlite` (and `history.sqlite-wal`, `history.sqlite-shm`) and the `history/` folder.
To remove everything, delete `~/Library/Application Support/Larynx/` (this includes the downloaded models) and
`~/Library/Logs/Larynx.log`.
