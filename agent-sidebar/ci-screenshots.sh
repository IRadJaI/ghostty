#!/bin/bash
# agent-sidebar: launch a built Ghostty.app with sample sidebar content and
# capture the screen in dark and light appearance.
#
#   ci-screenshots.sh <path/to/Ghostty.app> <output-dir>
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

# Temporary bisect: launch each sidebar variant and count AttributeGraph
# cycle reports on stderr.
{
  echo "variant  cycles   (0 none, 1 placeholder, 2 no backdrop, 3 no header, 4 no list, 5 full, 6 no model, 7 plain divider, 8 plain list)"
  for variant in 0 1 2 3 4 5 6 7 8; do
    echo "window-save-state = never" > "$work/ghostty/config"
    echo "confirm-close-surface = false" >> "$work/ghostty/config"
    echo "auto-update = off" >> "$work/ghostty/config"
    echo "command = $work/demo.sh" >> "$work/ghostty/config"
    open -n --env GHOSTTY_AGENT_SIDEBAR_DEMO=1 --env GHOSTTY_AGENT_SIDEBAR_VARIANT=$variant \
      --env XDG_CONFIG_HOME="$work" --stderr "$work/err-$variant.txt" "$app"
    sleep 9
    pkill -f "Ghostty.app/Contents/MacOS/ghostty" || true
    sleep 2
    echo "$variant        $(grep -c 'cycle detected' "$work/err-$variant.txt" 2>/dev/null || true)"
  done
} | tee "$out/variants.txt"

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
    --stdout "$out/stdout-$theme.txt" --stderr "$out/stderr-$theme.txt" "$app"
  sleep 12
  osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "ghostty") to true' || true
  sleep 2
  screencapture -x "$out/sidebar-$theme.png" || true
  # Call stacks of the running app: shows what the main thread is doing if
  # the UI did not update.
  pid="$(pgrep -f 'Ghostty.app/Contents/MacOS/ghostty' | head -1)"
  if [ -n "$pid" ]; then
    sample "$pid" 2 -file "$out/sample-$theme.txt" >/dev/null 2>&1 || true
    # Runtime warnings from SwiftUI / AttributeGraph end up in the unified log.
    log show --last 40s --style compact --predicate "processID == $pid" 2>/dev/null \
      | grep -iE 'swiftui|attributegraph|cycle|publishing|state|fault|error' | tail -200 > "$out/log-$theme.txt" || true
  fi
  pkill -f "Ghostty.app/Contents/MacOS/ghostty" || true
  sleep 3
done
ls -la "$out"
