#!/usr/bin/env bash
# capture-window.sh <window-name-substring> <out.png>
# Screenshot a specific window by id (reliable even when not frontmost).
#
# Mechanism: osascript(JXA) enumerates on-screen windows via the ObjC bridge
# to CGWindowListCopyWindowInfo, finds the first whose kCGWindowName contains
# the substring, prints "<id> <x> <y> <w> <h>", then `screencapture -x -o
# -l<id>` grabs it. We crop by the detected window bounds (the desktop
# wallpaper defeats screencapture's brightness-based auto-crop).
#
# VERIFY ON FIRST USE: JXA ObjC bridging + the CGWindowList key names are
# stable AppKit API, but this script has not been executed in this session.
# If the JXA lookup prints nothing, the window title didn't match or Screen
# Recording permission is missing (it is granted for this project per
# CLAUDE.md — do NOT request Computer Access to "fix" it).
set -euo pipefail

needle="${1:?usage: capture-window.sh <window-name-substring> <out.png>}"
out="${2:?usage: capture-window.sh <window-name-substring> <out.png>}"

read -r wid x y w h < <(osascript -l JavaScript <<JXA || true
ObjC.import('CoreGraphics');
ObjC.import('Foundation');
const info = \$.CGWindowListCopyWindowInfo(
  \$.kCGWindowListOptionOnScreenOnly | \$.kCGWindowListExcludeDesktopElements,
  \$.kCGNullWindowID);
const arr = ObjC.deepUnwrap(info);
const needle = "$needle";
for (const win of arr) {
  const name = win.kCGWindowName || "";
  if (name.indexOf(needle) !== -1) {
    const b = win.kCGWindowBounds;
    console.log([win.kCGWindowNumber, b.X, b.Y, b.Width, b.Height].join(" "));
    break;
  }
}
JXA
)

if [[ -z "${wid:-}" ]]; then
  echo "No on-screen window title contains: $needle" >&2
  exit 1
fi

screencapture -x -o -l"$wid" "$out"
echo "Captured window $wid ($needle) -> $out  bounds=${x},${y} ${w}x${h}"
