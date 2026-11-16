# Speaks a scripted meeting (tests/meetings/client-call.json, synthetic text) with Windows' built-in voices: each line
# to its own 16 kHz WAV, then make-meeting.py lays them out as two tracks, "you" (the microphone) and "call" (the
# computer's sound), the way meeting mode records them.
param([string]$Out = "meeting", [string]$Script = "tests/meetings/client-call.json")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Speech
New-Item -ItemType Directory -Force -Path "$Out/lines" | Out-Null
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voices = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo.Name })
if (-not $voices) { throw "no voices installed" }
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$meeting = Get-Content $Script -Raw | ConvertFrom-Json
$i = 0
foreach ($line in $meeting.lines) {
  $who = $line[0]
  # Two voices when the runner has them, so the sides sound different; one is enough for the test.
  $voice = if ($who -eq "You") { $voices[0] } else { $voices[[math]::Min(1, $voices.Count - 1)] }
  $synth.SelectVoice($voice)
  $synth.SetOutputToWaveFile((Join-Path (Resolve-Path "$Out/lines") ("{0:d3}.wav" -f $i)), $fmt)
  $synth.Speak($line[1])
  $synth.SetOutputToNull()
  $i++
}
python windows/ci/make-meeting.py $Script "$Out"
if ($LASTEXITCODE -ne 0) { throw "make-meeting.py failed" }
