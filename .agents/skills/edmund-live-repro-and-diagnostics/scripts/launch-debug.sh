#!/usr/bin/env bash
# launch-debug.sh <file.md> [script.repro]
# Assemble/refresh build/EdmundDbg.app, then direct-exec it with diagnostic
# flags (and optionally replay a ReproScript). Kills only its OWN prior debug
# instance, never the user's daily-driver edmd.
#
# Steps (from docs/dev-guides/live-repro-guide.md §4):
#   1. swift build (debug).
#   2. Assemble EdmundDbg.app: Info.plist copy + debug edmd + Sparkle.framework
#      (dyld aborts without the framework; a bare .build/debug/edmd never makes
#      a window).
#   3. Refuse to run if a non-ours edmd is live (check-live-instance.sh).
#   4. Direct-exec the bundle binary (never `open -a`: LaunchServices can run a
#      stale translocated copy).
#
# VERIFY ON FIRST USE: paths assume the standard arm64 debug layout
# `.build/arm64-apple-macosx/debug/`. If your host resolves a different triple,
# adjust BUILD_DIR. Binary-freshness check is a reminder, not enforced here —
# see edmund-build-and-env for the strings/shasum method.
set -euo pipefail

doc="${1:?usage: launch-debug.sh <file.md> [script.repro]}"
repro="${2:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"   # repo root
cd "$ROOT"
BUILD_DIR=".build/arm64-apple-macosx/debug"
APP="build/EdmundDbg.app"

# 0. Never step on the user's instance.
here="$(dirname "${BASH_SOURCE[0]}")"
if pgrep -x edmd >/dev/null 2>&1; then
  # Allow only if it's our own EdmundDbg (safe to replace).
  if ! pgrep -f EdmundDbg >/dev/null 2>&1; then
    echo "A non-EdmundDbg edmd is running — refusing to launch. Inspect:" >&2
    bash "$here/check-live-instance.sh" || true
    exit 2
  fi
  pkill -f EdmundDbg || true
fi

# 1. Build.
swift build

# 2. Assemble the bundle.
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BUILD_DIR/edmd" "$APP/Contents/MacOS/edmd"
if [[ -d "$BUILD_DIR/Sparkle.framework" ]]; then
  rm -rf "$APP/Contents/MacOS/Sparkle.framework"
  cp -R "$BUILD_DIR/Sparkle.framework" "$APP/Contents/MacOS/Sparkle.framework"
else
  echo "WARNING: $BUILD_DIR/Sparkle.framework not found; dyld may abort." >&2
fi

# 3. Launch by direct exec, background, with diagnostics on.
args=( "$doc"
       -settings.general.diagnosticLogging YES
       -settings.advanced.verboseEditorDiagnostics YES
       -ApplePersistenceIgnoreState YES )
if [[ -n "$repro" ]]; then
  args+=( -debug.reproScript "$repro" )
fi

echo "Launching $APP with: ${args[*]}"
"$APP/Contents/MacOS/edmd" "${args[@]}" &
echo "Launched PID $! — tail with: scripts/grep-trace.sh"
