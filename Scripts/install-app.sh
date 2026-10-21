#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$HOME/Applications/Photo Reader.app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/PhotoReader"
osascript -e 'quit app "Photo Reader"' >/dev/null 2>&1 || true
sleep 1; pkill -x PhotoReader >/dev/null 2>&1 || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoReader"
PLIST="$APP/Contents/Info.plist"
cp "Resources/Info.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable PhotoReader" "$PLIST" \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string PhotoReader" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.tara.photoreader" "$PLIST" \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.tara.photoreader" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$PLIST" \
  || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
codesign --force --deep -s - "$APP"
open "$APP"
echo "Installed and launched: $APP"
