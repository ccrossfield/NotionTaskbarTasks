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
</dict>
</plist>
PLIST

echo "Built $APP"
echo "Run it with:  open $APP"
echo "(a checklist icon should appear in the menu bar; there is no Dock icon)"
