#!/bin/zsh
# Builds Larynx.app (menu bar dictation) into ~/Applications and signs it ad hoc.
set -euo pipefail
cd "${0:a:h}/.."
swift build -c release
APP="${1:-$HOME/Applications}/Larynx.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/larynx "$APP/Contents/MacOS/larynx"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.automatedworkflow.larynx</string>
  <key>CFBundleName</key><string>Larynx</string>
  <key>CFBundleDisplayName</key><string>Larynx</string>
  <key>CFBundleExecutable</key><string>larynx</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Larynx listens while you hold the talk key and turns your speech into text, on this Mac.</string>
</dict></plist>
PLIST
# A stable identity keeps macOS permissions across rebuilds (see scripts/make-signing-cert.sh); ad hoc otherwise.
IDENTITY="-"
security find-certificate -c "Larynx Local Signing" >/dev/null 2>&1 && IDENTITY="Larynx Local Signing"
codesign --force --sign "$IDENTITY" --identifier com.automatedworkflow.larynx "$APP"
echo "signed with: $IDENTITY"
echo "$APP"
