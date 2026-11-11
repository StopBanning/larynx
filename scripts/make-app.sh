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
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.automatedworkflow.larynx</string>
  <key>CFBundleName</key><string>Larynx</string>
  <key>CFBundleDisplayName</key><string>Larynx</string>
  <key>CFBundleExecutable</key><string>larynx</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Larynx listens while you hold the talk key and turns your speech into text, on this Mac.</string>
</dict></plist>
PLIST
# A stable identity keeps macOS permissions across rebuilds (see scripts/make-signing-cert.sh); ad hoc otherwise.
# Preference: a real Apple Development identity (free personal team in Xcode; needed for Apple's on-device model),
# then the local certificate, then ad hoc.
IDENTITY="-"
security find-certificate -c "Larynx Local Signing" >/dev/null 2>&1 && IDENTITY="Larynx Local Signing"
APPLE_ID=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
[ -n "$APPLE_ID" ] && IDENTITY="$APPLE_ID"
codesign --force --sign "$IDENTITY" --identifier com.automatedworkflow.larynx "$APP"
echo "signed with: $IDENTITY"
# The Neural Engine compiles a model the first time this bundle id loads it (about 95 s for Parakeet Ultra), and the
# app would sit deaf meanwhile. Load the configured model once with the app's own binary so the cache is warm before
# restart-app.sh. LARYNX_NO_WARM=1 skips it.
if [ -z "${LARYNX_NO_WARM:-}" ]; then
  START=$(date +%s)
  if "$APP/Contents/MacOS/larynx" transcribe tests/fixtures/report.wav \
       --models-dir "$HOME/Library/Application Support/Larynx/models" >/dev/null 2>&1; then
    echo "speech model warm ($(( $(date +%s) - START )) s)"
  else
    echo "speech model warm-up skipped (the app will compile it on first use)"
  fi
fi
echo "$APP"
