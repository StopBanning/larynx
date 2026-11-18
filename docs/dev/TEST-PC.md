# The Windows test PC

CI runs the Windows app on GitHub's virtual machines on every push (`.github/workflows/windows.yml`): dictation into
Notepad, meeting mode in three rooms, meeting mode through a virtual audio cable with a headset unplugged mid-meeting,
the panel at three screen scalings, and "Send a report…". What a virtual machine can't show is a real PC: its sound
chip, microphone and speakers, its speed, an installed and signed-in Claude Code, Windows' warnings for an unsigned
app, and how it feels to use. A cheap laptop, plugged in and left on, covers that. It is also the worst case:
what works on it works on most PCs.

## What to buy

Used is fine, around $100-150.

- **Windows 11**, or a laptop that can take it (8th-gen Intel Core / Ryzen 2000 or newer).
- **Intel or AMD**, not Snapdragon (ARM): most people's PCs are x64, and that's what the app is built for first.
- **8 GB of memory.** 4 GB is too little for the speech model next to a browser.
- **An SSD**, not a spinning disk.
- **Its own microphone and speakers, working.** Meeting mode's hardest case is the call coming out of the speakers
  into the microphone, so those are the point.

## Setting it up (once, about 10 minutes at the laptop)

1. Install Windows updates and restart until there are none left.
2. Power: Settings → System → Power → when plugged in, screen and sleep **Never**. Leave it plugged in.
3. Stay signed in: the tests need a desktop. Turn on automatic sign-in (Sysinternals Autologon, from Microsoft) and
   turn off the lock screen after sleep (Settings → Accounts → Sign-in options → "If you've been away" → Never).
4. Remote login, in PowerShell as administrator:

   ```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service sshd -StartupType Automatic
   ```

   Then add the Mac's public key (`~/.ssh/id_ed25519.pub` on the Mac) to
   `C:\ProgramData\ssh\administrators_authorized_keys` (for an administrator account) and lock that file down:

   ```powershell
   icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
   ```

   Note the laptop's address (Settings → Network → properties → IPv4) and check `ssh <user>@<address>` works from
   the Mac. Give it a fixed address in the router so it doesn't move.
5. Claude Code: install it the way its Windows instructions say, run `claude` once in a terminal **at the laptop**
   and sign in. Signing in is a person's job; it stays signed in after that.

## How tests run on it

A program started over SSH runs in a session with no desktop and no sound, so it can't show the pill or hear the
microphone. Tests therefore start on the signed-in desktop through a scheduled task:

```powershell
schtasks /create /tn LarynxTest /tr "C:\larynx\run-test.cmd" /sc once /st 00:00 /it /f
schtasks /run /tn LarynxTest
```

`/it` runs it in the signed-in user's desktop session. The test writes its results to a folder that is then copied
back to the Mac with `scp`. Builds come from the CI artifact (`larynx-windows-x64`) or the Windows beta.

What to run there that CI can't:

- Dictation and meeting mode with the laptop's own microphone and speakers, at a normal volume, in a normal room.
- The speech model's speed on a real CPU (`larynx-cli bench`), and on its GPU if it has one (`--provider directml`).
- First run from the beta zip: the unknown-publisher warning, the model download, the tray icon.
- Notes through the real, signed-in Claude Code.
- A real headset: plugged in, unplugged and Bluetooth, mid-meeting.
- The meeting panel's glass: on a real graphics card the desktop should show blurred through it while another app
  (the call) is the active window. CI has no graphics card, so it only ever sees Acrylic's flat stand-in colour.
  The panel's log line `panel_look` says whether Windows gave it glass.

Nothing from a real person's dictation or meetings goes back into the repository: test sentences are made up, as in CI.
