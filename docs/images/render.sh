#!/usr/bin/env bash
# Render the README mockups (docs/images/mockups.html) to PNGs with headless
# Chrome. Each scene is captured at its authored size (920px wide, scale 1).
# Re-run after editing mockups.html.
set -euo pipefail
cd "$(dirname "$0")"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SRC="file://$(pwd)/mockups.html"

# scene:height (width is always 920)
scenes=(
  "task-list:960"
  "search:600"
  "quick-add:600"
  "quick-capture:440"
  "claude-code:560"
  "custom-view:820"
  "dark-mode:960"
  "connect:454"
)

for entry in "${scenes[@]}"; do
  name="${entry%%:*}"
  h="${entry##*:}"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --force-device-scale-factor=1 --window-size="920,${h}" \
    --screenshot="$(pwd)/${name}.png" "${SRC}?scene=${name}" >/dev/null 2>&1
  echo "rendered ${name}.png (920x${h})"
done
