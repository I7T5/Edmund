#!/usr/bin/env bash
# capture-window.sh <window-name-substring> <out.png>
# Screenshot a window by id — reliable even when the window is not frontmost,
# and without stealing focus.
#
# This used to do the window lookup in JXA. That never worked: under osascript,
# `ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(...))` returns a value with no
# `.length`, so the loop silently found nothing and the script reported "no
# window" for windows that were plainly on screen. Verified broken 2026-07-26;
# the lookup now goes through `winid.swift`, which is exercised routinely.
#
# For driving Edmund's own UI (open the find bar, toggle the replace row,
# force light/dark), use `ui-harness.sh` — it wraps this plus the AX driving.
set -euo pipefail

needle="${1:?usage: capture-window.sh <window-name-substring> <out.png>}"
out="${2:?usage: capture-window.sh <window-name-substring> <out.png>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Scan every edmd process for a window whose title contains the needle.
line=""
for pid in $(pgrep -x edmd 2>/dev/null || true); do
  line="$(swift "$HERE/winid.swift" "$pid" | grep -F "name=" | grep -F "$needle" | head -1 || true)"
  [[ -n "$line" ]] && break
done

if [[ -z "$line" ]]; then
  echo "No window title contains: $needle" >&2
  exit 1
fi

wid="${line#id=}"; wid="${wid%% *}"
screencapture -x -o -l"$wid" "$out"
echo "Captured window $wid -> $out  ($line)"
