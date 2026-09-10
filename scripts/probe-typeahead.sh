#!/usr/bin/env bash
# Live probe for the type-ahead search (#41/#49): opens the panel with its
# hotkey, posts a burst of keystrokes, reads the focused field back through
# accessibility, and closes the panel. Prints OK when every letter landed.
#
# This is the regression check for a shell-timing bug the check suite can't
# reach: fast typing after the seed used to drop letters or replace the seed
# (#49). Run against the built .app with the default panel hotkey (⌥⇧Space):
#
#   scripts/probe-typeahead.sh            # "qwe" as one burst
#   scripts/probe-typeahead.sh qw         # two letters, the minimal case
#   scripts/probe-typeahead.sh qwe 0.3 0.15   # 150ms between keys (human speed)
#
# Args: <text> <seconds to wait after opening> <seconds between keys, 0 = burst>.
# Needs Accessibility permission for the terminal. Refuses to type unless the
# panel is confirmed open, so stray letters can't reach another app. Each cycle
# briefly takes keyboard focus, so don't run it while typing elsewhere.
count() { osascript -e 'tell application "System Events" to count windows of process "NotionTasks"' 2>/dev/null || echo 0; }
n=$(count); [ "${n:-0}" != "0" ] && { echo "abort: panel already open"; exit 2; }
osascript -e 'tell application "System Events" to key code 49 using {option down, shift down}'
sleep "$post_open"
n=$(count); [ "${n:-0}" != "1" ] && { echo "abort: panel did not open (count=$n) - not typing"; exit 3; }
got=$(osascript - "$typed" "$per_key" <<'APPLESCRIPT'
on run argv
  set s to item 1 of argv
  set gap to (item 2 of argv) as real
  tell application "System Events"
    if gap = 0 then
      keystroke s
    else
      repeat with c in characters of s
        keystroke (c as text)
        delay gap
      end repeat
    end if
    delay 0.5
    tell process "NotionTasks"
      try
        set f to value of attribute "AXFocusedUIElement"
        if role of f is "AXTextField" then
          set v to value of f as text
        else
          set v to "<focused is " & (role of f) & ">"
        end if
      on error e
        set v to "<error: " & e & ">"
      end try
    end tell
  end tell
  return v
end run
APPLESCRIPT
)
# close: hotkey toggles the panel shut (also clears the search on teardown)
osascript -e 'tell application "System Events" to key code 49 using {option down, shift down}'; sleep 0.3
n=$(count); [ "${n:-0}" != "0" ] && echo "warn: panel still open after close (count=$n)"
if [ "$got" = "$typed" ]; then echo "typed=$typed gap=$per_key got=$got OK"; else echo "typed=$typed gap=$per_key got=$got MISS"; fi
