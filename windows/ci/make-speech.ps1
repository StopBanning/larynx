# Speaks each sentence in sentences.json with Windows' built-in voice into 16 kHz mono WAV files and writes a
# manifest for `larynx bench`. Synthetic text only: no one's real dictation.
param([string]$Out = "speech")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Speech
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voices = $synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo.Name }
Write-Host "voices: $($voices -join ', ')"
if (-not $voices) { throw "no voices installed" }
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$items = Get-Content (Join-Path $PSScriptRoot "sentences.json") -Raw | ConvertFrom-Json
$manifest = @()
foreach ($item in $items) {
  $file = "$($item.id).wav"
  $synth.SetOutputToWaveFile((Join-Path (Resolve-Path $Out) $file), $fmt)
  $synth.Speak($item.text)
  $synth.SetOutputToNull()
  $manifest += [ordered]@{ wav = $file; text = $item.text }
}
$manifest | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $Out "manifest.json")
Get-ChildItem $Out
