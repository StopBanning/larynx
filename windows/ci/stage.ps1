# Puts everything Larynx needs to run into one folder: larynx.exe, ONNX Runtime (with DirectML), the Swift cleanup
# library with its word list, and the Swift runtime DLLs it needs. No Swift or Rust toolchain is needed to run it.
param([string]$Dist = "dist")
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
$rel = "windows/target/release"
Copy-Item "$rel/larynx.exe", "$rel/larynx-cli.exe" $Dist
Get-ChildItem $rel -Filter *.dll | Copy-Item -Destination $Dist
$swiftOut = (Get-ChildItem .build -Recurse -Filter LarynxTextC.dll | Where-Object { $_.FullName -match 'release' } | Select-Object -First 1).Directory
Copy-Item "$swiftOut/LarynxTextC.dll" $Dist
Get-ChildItem $swiftOut -Directory -Filter *.resources | Copy-Item -Destination $Dist -Recurse -Force
# The Swift runtime: swiftCore, Foundation and friends, from the toolchain's redistributable folder.
$roots = @("$env:LOCALAPPDATA\Programs\Swift", "$env:ProgramFiles\Swift", "C:\Library", "$env:SystemDrive\Swift") | Where-Object { Test-Path $_ }
$core = Get-ChildItem $roots -Recurse -Filter swiftCore.dll -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'Runtimes' -and $_.FullName -match 'bin' } | Select-Object -First 1
if (-not $core) { $core = Get-ChildItem $roots -Recurse -Filter swiftCore.dll -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not $core) { throw "Swift runtime not found under $roots" }
Write-Host "Swift runtime: $($core.Directory)"
Get-ChildItem $core.Directory -Filter *.dll | Copy-Item -Destination $Dist
Get-ChildItem $Dist -Recurse | Select-Object FullName, Length | Format-Table -AutoSize
$mb = [math]::Round(((Get-ChildItem $Dist -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host "dist size: $mb MB"
