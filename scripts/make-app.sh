#!/bin/zsh
# Builds Larynx.app (menu bar dictation) into ~/Applications and signs it ad hoc.
set -euo pipefail
cd "${0:a:h}/.."
swift build -c release
APP="${1:-$HOME/Applications}/Larynx.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/larynx "$APP/Contents/MacOS/larynx"
# SwiftPM resources must travel with the executable, including the portable spelling fallback and its licence.
mkdir -p "$APP/Contents/Resources"
cp -R .build/release/Larynx_LarynxText.bundle "$APP/Contents/Resources/"
# The icon is drawn by scripts/make-icon.swift and kept in the repo, so a build never has to draw it.
cp packaging/Larynx.icns "$APP/Contents/Resources/Larynx.icns"
# Licences: Larynx's own, the credits (every model and its licence), and the texts of the code compiled in.
LIC="$APP/Contents/Resources/Licenses"
mkdir -p "$LIC/FluidAudio"
cp LICENSE packaging/CREDITS.md "$LIC/"
mkdir -p "$APP/Contents/Resources/fonts"
cp packaging/fonts/PaperMono.ttf "$APP/Contents/Resources/fonts/"
cp packaging/fonts/OFL.txt "$LIC/PaperMono-OFL.txt"
cp .build/checkouts/FluidAudio/LICENSE "$LIC/FluidAudio/"
cp -R .build/checkouts/FluidAudio/ThirdPartyLicenses "$LIC/FluidAudio/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.automatedworkflow.larynx</string>
  <key>CFBundleName</key><string>Larynx</string>
  <key>CFBundleDisplayName</key><string>Larynx</string>
  <key>CFBundleExecutable</key><string>larynx</string>
  <key>CFBundleIconFile</key><string>Larynx</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.7.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Larynx listens while you hold the talk key and turns your speech into text, on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>When you record a meeting, Larynx hears the call (Zoom, Teams, FaceTime and others) so your notes include everyone, not just you. The audio stays on this Mac.</string>
</dict></plist>
PLIST
# A stable identity keeps macOS permissions across rebuilds (see scripts/make-signing-cert.sh); ad hoc otherwise.
# Preference: a real Apple Development identity (free personal team in Xcode; needed for Apple's on-device model),
# then the local certificate, then ad hoc.
IDENTITY="-"
security find-certificate -c "Larynx Local Signing" >/dev/null 2>&1 && IDENTITY="Larynx Local Signing"
APPLE_ID=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
[ -n "$APPLE_ID" ] && IDENTITY="$APPLE_ID"
# LARYNX_SIGN=adhoc ignores any identity on this Mac: what someone else's build looks like (tests/install.py, CI).
[ "${LARYNX_SIGN:-}" = adhoc ] && IDENTITY="-"
codesign --force --sign "$IDENTITY" --identifier com.automatedworkflow.larynx "$APP"
echo "signed with: $IDENTITY"
# The Neural Engine compiles a model the first time this bundle id loads it (about 95 s for Parakeet Ultra), and the
# app would sit deaf meanwhile. Load the configured model once with the app's own binary so the cache is warm before
# restart-app.sh. Only models already on this Mac: loading a missing one downloads it, and a first install must get its
# one model in the app, with a progress bar, not hundreds of megabytes in a silent Terminal (nor a backup model it never
# asked for). LARYNX_NO_WARM=1 skips it.
MODELS="$HOME/Library/Application Support/Larynx/models"
folder_for() {
  case "$1" in
    clean) echo bark-3.0-clean ;; bark3) echo bark-3.0 ;; parakeet) echo parakeet-tdt-0.6b-v3 ;;
    unified) echo parakeet-unified-en-0.6b ;; *) echo parakeet-ultra ;;
  esac
}
on_disk() { ls "$MODELS/$(folder_for "$1")" 2>/dev/null | grep -q '\.mlmodelc$'; }
ENGINE=$(plutil -extract engine raw -o - "$HOME/Library/Application Support/Larynx/settings.json" 2>/dev/null || echo ultra)
if [ -n "${LARYNX_NO_WARM:-}" ]; then
  :
elif ! on_disk "$ENGINE"; then
  echo "speech model: downloads on first launch, in the app"
else
  START=$(date +%s)
  if "$APP/Contents/MacOS/larynx" transcribe tests/fixtures/report.wav --engine "$ENGINE" --models-dir "$MODELS" >/dev/null 2>&1; then
    echo "speech model warm ($(( $(date +%s) - START )) s)"
    # The backup model (tried when the main one hears nothing) compiles on first use too: a 160 s stall once.
    for backup in clean parakeet; do
      [ "$backup" = "$ENGINE" ] && continue
      on_disk "$backup" || continue
      "$APP/Contents/MacOS/larynx" transcribe tests/fixtures/report.wav --engine $backup --models-dir "$MODELS" >/dev/null 2>&1 && break
    done
  else
    echo "speech model warm-up skipped (the app will compile it on first use)"
  fi
fi
echo "$APP"
