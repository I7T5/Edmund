#!/bin/bash
# Marketing / App Store screenshots of the real app, light and dark.
#
# Usage: scripts/screenshots.sh [pattern]      e.g. scripts/screenshots.sh settings
#
# Each scripts/screenshots/<name>.shot is a ReproScript scenario (commands:
# header of Sources/edmd/App/ReproScript.swift) that sets up one state. Headers:
#   # doc: <path>      document to open, relative to the repo root (or $SHOTS_DOC_ROOT)
#   # args: <flags>    extra launch arguments, shell-quoted (settings, toolbar layout)
#   # modes: <list>    default "light dark"
#   # window: w,h      window size in points, default 1200,750
#   # offset: dx,dy    with several windows, shift each by this fraction of the
#                      canvas from the one before (cascade, side by side)
#   # compose: no      capture only, for use by a combined shot
#   # combine: <shot>...  no run of its own: the key windows of those shots'
#                      captures, in order, on one canvas (with # offset:)
# The runner sizes the window and brings it to the front before
# the scenario, then `screencapture -l`s every visible window with its shadow
# and stacks them, key window on top, on a 2880×1800 gradient
# (scripts/screenshots/compose.swift).
#
# Output: $SHOTS_OUT (default misc/screenshots/<version>/):
# raw/<name>-<mode>-<n>.png (one window + shadow, transparent) and
# <name>-<mode>.png (App Store size, no alpha).
#
# Extensions (Mermaid, Advanced Math) render only once their payload is in
# ~/Library/Application Support/Edmund — the bundle is unsandboxed, so the
# sandboxed app's downloads in its container don't count.
#
# The app runs from a debug bundle with its own bundle id
# (com.i7t5.edmund.shots), so it starts from factory settings and never reads
# or writes the real app's preferences or saved window frame. Typewriter mode is
# off so the document starts at the top.
#
# Activation: `front` has to make Edmund the active app, or the window captures
# with grey traffic lights and a smaller shadow. macOS refuses that while you
# are typing in another app, so leave the machine alone during a run; a refused
# capture is retried up to 3 times. Anything that only draws fully in the key
# window (find's yellow match highlights, selection colour) needs an idle machine.
#
# compose.swift also works on its own, on captures you take by hand
# (⇧⌘4, Space, click a window — shadow included).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PATTERN="${1:-}"
DOC_ROOT="${SHOTS_DOC_ROOT:-$ROOT}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
OUT="${SHOTS_OUT:-$ROOT/misc/screenshots/$VERSION}"
mkdir -p "$OUT/raw"

echo "== building shots bundle"
swift build 2>&1 | grep -E "error:|Build complete" | tail -2
BIN="$(swift build --show-bin-path)"
APP="build/EdmundShots.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.i7t5.edmund.shots "$APP/Contents/Info.plist"
cp "$BIN/edmd" "$APP/Contents/MacOS/edmd"
[ -d "$BIN/Sparkle.framework" ] && cp -R "$BIN/Sparkle.framework" "$APP/Contents/MacOS/"
for bundle in "$BIN"/*.bundle; do [ -e "$bundle" ] && cp -R "$bundle" "$APP/"; done
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Edmund.help "$APP/Contents/Resources/"
# The accent colour lives in the asset catalog; without it controls draw blue.
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist "$(mktemp)" >/dev/null

RUN="$(mktemp -d)"

# capture <doc> <script> <raw prefix> [args...] → 0 when a key window was
# captured. Writes <prefix>-<n>.png per visible window, the key window last.
capture() {
    local doc="$1" script="$2" prefix="$3"; shift 3
    local log="$script.log"
    rm -f "$log" "$prefix"-*.png
    # Factory settings every run: the toolbar layout, window frame and panes
    # one shot leaves behind would otherwise show up in the next.
    defaults delete com.i7t5.edmund.shots >/dev/null 2>&1
    "$ROOT/$APP/Contents/MacOS/edmd" "$doc" -debug.reproScript "$script" \
        -debug.disableUpdater YES -NSAppSleepDisabled YES -ApplePersistenceIgnoreState YES \
        -EditorTypewriterMode NO "$@" >/dev/null 2>&1 &
    local pid=$! got=1
    for _ in $(seq 1 600); do
        kill -0 "$pid" 2>/dev/null || break
        if grep -q '^repro window ' "$log" 2>/dev/null; then
            sleep 0.2   # every window's line is in
            if grep -q '^repro window .* key=true' "$log"; then
                local n=0 wid
                for wid in $(grep '^repro window .* key=false' "$log" | awk '{print $3}') \
                           $(grep '^repro window .* key=true' "$log" | awk '{print $3}'); do
                    n=$((n + 1))
                    screencapture -x -l "$wid" "$prefix-$n.png"
                done
                got=0
            fi
            break
        fi
        sleep 0.1
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return $got
}

header() { sed -n "s/^# $2: *//p" "$1" | head -1; }

shots=0; failed=()
for shot in scripts/screenshots/*.shot; do
    name="$(basename "$shot" .shot)"
    [[ -n "$PATTERN" && "$name" != *$PATTERN* ]] && continue
    [ -n "$(header "$shot" combine)" ] && continue   # composed below
    doc="$DOC_ROOT/$(header "$shot" doc)"
    modes="$(header "$shot" modes)"
    size="$(header "$shot" window)"
    offset="$(header "$shot" offset)"
    eval "set -- $(header "$shot" args)"
    if [ ! -f "$doc" ]; then
        echo "FAIL  $name  (doc missing: $doc)"; failed+=("$name"); continue
    fi
    # Documents autosave in place: open a copy of the doc's folder (images too).
    rm -rf "$RUN/$name-docs"; cp -R "$(dirname "$doc")" "$RUN/$name-docs"
    doc="$RUN/$name-docs/$(basename "$doc")"
    for mode in ${modes:-light dark}; do
        script="$RUN/$name-$mode.repro"
        # `front` first, so a window the scenario opens (Settings) ends up key.
        { printf '%s\n' "resizewindow ${size:-1200,750}" front 'sleep 1000'; grep -v '^#' "$shot"
          printf '%s\n' 'sleep 2500' logwindows 'sleep 1500' done; } > "$script"
        raw="$OUT/raw/$name-$mode"
        ok=""
        for attempt in 1 2 3; do
            capture "$doc" "$script" "$raw" -settings.appearance.mode "$mode" "$@" && { ok=1; break; }
            echo "      $name-$mode: window not active (attempt $attempt), retrying"
        done
        if [ -z "$ok" ]; then
            echo "FAIL  $name-$mode"; failed+=("$name-$mode"); continue
        fi
        if [ "$(header "$shot" compose)" = no ]; then
            echo "ok    $name-$mode (raw only)"; continue
        fi
        swift scripts/screenshots/compose.swift "$OUT/$name-$mode.png" "$mode" \
            ${offset:+--offset "$offset"} "$raw"-*.png
        echo "ok    $name-$mode"
        shots=$((shots + 1))
    done
done

# Combined shots: the key window of each listed shot (its last raw capture),
# in order, on one canvas. Runs after the captures, from whatever raw/ holds.
for shot in scripts/screenshots/*.shot; do
    name="$(basename "$shot" .shot)"
    [[ -n "$PATTERN" && "$name" != *$PATTERN* ]] && continue
    parts="$(header "$shot" combine)"
    [ -n "$parts" ] || continue
    offset="$(header "$shot" offset)"
    modes="$(header "$shot" modes)"
    for mode in ${modes:-light dark}; do
        windows=()
        for part in $parts; do
            last="$(ls "$OUT/raw/$part-$mode"-*.png 2>/dev/null | tail -1)"
            [ -n "$last" ] || { echo "FAIL  $name-$mode  (no capture of $part)"; failed+=("$name-$mode"); continue 2; }
            windows+=("$last")
        done
        swift scripts/screenshots/compose.swift "$OUT/$name-$mode.png" "$mode" \
            ${offset:+--offset "$offset"} "${windows[@]}"
        echo "ok    $name-$mode (combined)"
        shots=$((shots + 1))
    done
done

echo ""
echo "== $shots screenshots in $OUT"
[ ${#failed[@]} -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
