#!/bin/bash
# agent-sidebar: launch a built Ghostty.app with sample sidebar content and
# capture the screen in dark and light appearance.
#
#   ci-screenshots.sh <path/to/Ghostty.app> <output-dir>
#
# It also exercises the fork's control socket (ci-socket-test.py) and saves
# the transcript.
#
# Used by .github/workflows/agent-sidebar.yml; also works on a local Mac.
set -u
app="$1"
out="$2"
work="$(mktemp -d)"
mkdir -p "$out" "$work/ghostty"

cat > "$work/demo.sh" <<'DEMO'
#!/bin/sh
printf 'me@mac acme-web %% git status\nOn branch main\nnothing to commit, working tree clean\nme@mac acme-web %% npm test\n\n PASS  src/checkout.test.ts (12 tests)\n PASS  src/settings.test.ts (20 tests)\n\nme@mac acme-web %% '
sleep 600
DEMO
chmod +x "$work/demo.sh"

# A colourful desktop makes translucency visible in the screenshots, and the
# accessibility setting tells whether this machine draws translucency at all.
echo "reduceTransparency: $(defaults read com.apple.universalaccess reduceTransparency 2>&1 | tail -1)"
wallpaper="$(ls /System/Library/Desktop\ Pictures/*.heic /System/Library/Desktop\ Pictures/*.jpg 2>/dev/null | head -1)"
echo "wallpaper: $wallpaper"
if [ -n "$wallpaper" ]; then
  osascript -e "tell application \"System Events\" to set picture of every desktop to \"$wallpaper\"" || true
fi

for theme in dark light; do
  {
    echo "window-theme = $theme"
    echo "window-width = 110"
    echo "window-height = 30"
    echo "confirm-close-surface = false"
    echo "window-save-state = never"
    echo "auto-update = off"
    echo "command = $work/demo.sh"
    if [ "$theme" = light ]; then
      echo "background = ffffff"
      echo "foreground = 1d1f21"
    fi
  } > "$work/ghostty/config"

  open -n --env GHOSTTY_AGENT_SIDEBAR_DEMO=1 --env XDG_CONFIG_HOME="$work" \
    --stderr "$out/stderr-$theme.txt" "$app"
  sleep 12
  osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "ghostty") to true' || true
  sleep 2
  screencapture -x "$out/sidebar-$theme.png" || true
  # Call stacks of the running app: shows what the main thread is doing if
  # the UI did not update.
  pid="$(pgrep -f 'Ghostty.app/Contents/MacOS/ghostty' | head -1)"
  if [ -n "$pid" ]; then
    sample "$pid" 2 -file "$out/sample-$theme.txt" >/dev/null 2>&1 || true
  fi
  if [ "$theme" = dark ]; then
    # Exercise the control socket while the app is up, then capture the
    # window again: the test leaves the error-fix bar in its "review" state.
    python3 "$(dirname "$0")/ci-socket-test.py" > "$out/socket-test.txt" 2>&1 || true
    tail -3 "$out/socket-test.txt"
    screencapture -x "$out/sidebar-after-socket-test.png" || true
  fi
  pkill -f "Ghostty.app/Contents/MacOS/ghostty" || true
  sleep 3
  # SwiftUI reports update cycles on stderr; they freeze parts of the UI.
  echo "AttributeGraph cycles ($theme): $(grep -c 'cycle detected' "$out/stderr-$theme.txt" 2>/dev/null || true)" | tee -a "$out/cycles.txt"
done
ls -la "$out"
