#!/usr/bin/env bash
# Assemble a launchable menu-bar .app from the SwiftPM executable.
# SwiftPM produces a bare binary; macOS needs a bundle with an Info.plist
# (LSUIElement = menu-bar-only, no Dock icon) to run it as a proper app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product NotionTasksApp

APP="NotionTasks.app"
BIN=".build/release/NotionTasksApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NotionTasks"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NotionTasks</string>
  <key>CFBundleDisplayName</key><string>Notion Tasks</string>
  <key>CFBundleIdentifier</key><string>uk.co.pivotal.notiontasks</string>
  <key>CFBundleExecutable</key><string>NotionTasks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Notion Tasks opens iTerm2 to start working on a task in Claude Code.</string>
</dict>
</plist>
PLIST

# Code-sign with a stable identity if one exists, so the Keychain "Always Allow"
# survives rebuilds. Falls back to ad-hoc (which does NOT survive rebuilds — you
# get re-prompted for the token after each build). Override with CODESIGN_IDENTITY.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # Not `-v`: a self-signed identity is valid for signing but reported untrusted,
  # so it only appears without the "valid only" filter.
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/[0-9]+\) [0-9A-F]{40}/{print $2; exit}')"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed with code-signing identity $IDENTITY (Always Allow will persist across rebuilds)"
else
  codesign --force --deep --sign - "$APP"
  echo "Ad-hoc signed — no code-signing identity found."
  echo "  You'll be re-prompted for the token after each rebuild. To fix permanently,"
  echo "  create a self-signed 'Code Signing' certificate named e.g. 'NotionTasks Dev'"
  echo "  in Keychain Access (Certificate Assistant), then re-run this script."
fi

echo "Built $APP"
echo "Run it with:  open $APP"
echo "(a checklist icon should appear in the menu bar; there is no Dock icon)"
