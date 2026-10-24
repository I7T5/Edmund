#!/bin/bash
# Marketing / App Store screenshots of the real app, light and dark.
#
# Usage: scripts/screenshots.sh [pattern...]   e.g. scripts/screenshots.sh 3-table settings
#        scripts/screenshots.sh --failed       the shots the last rating put below the bar
# Only the named shots launch the app. Naming a combined shot retakes its
# parts; naming a part recomposes the combined shots built from it.
#
# Each scripts/screenshots/<name>.shot is a ReproScript scenario (commands:
# header of Sources/edmd/App/ReproScript.swift) that sets up one state. Headers:
#   # doc: <path>      document to open, relative to the repo root (or $SHOTS_DOC_ROOT)
#   # args: <flags>    extra launch arguments, shell-quoted (settings, toolbar layout)
#   # modes: <list>    default "light"; "light dark" for a pair's parts
#   # window: w,h      window size in points, default 960,600
#   # offset: dx,dy    with several windows, shift each by this fraction of the
#                      canvas from the one before (cascade, side by side)
#   # layout: x,y x,y… each window's centre as a fraction of the canvas, for
#                      arrangements a cascade can't make
#   # scale: s         the windows' scale, instead of the largest that fits
#                      (spread a layout without shrinking its windows)
#   # compose: no      capture only, for use by a combined shot
#   # combine: <shot>...  no run of its own: the key windows of those shots'
#                      captures, in order, on one canvas (with # offset:)
# The runner sizes the window and brings it to the front before
# the scenario, then `screencapture -l`s every visible window with its shadow
# and stacks them, key window on top, on a 2880×1800 canvas
# (scripts/screenshots/compose.swift): $SHOTS_BACKGROUND, default the current
# desktop picture, or a plain gradient with SHOTS_BACKGROUND=none.
# $SHOTS_SIZE (WxH, default 2880x1800, the App Store's) sizes the canvas; the
# same shots serve the README and edmund.md.
# $SHOTS_SRC builds the app from another source tree (default this repo), e.g.
# one with an unmerged fix the shots should show.
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
# with grey traffic lights and a smaller shadow. Each shot waits for 3 s with no
# keyboard or mouse input before it launches (keys typed while it is key land
# in the document), and a refused activation is retried up to 5 times.
#
#   # manual: <what to do>   the runner sets the window up, prints this, and
#                      takes the next screenshot you make (⇧⌘4, Space, click)
#                      — for states only a person can reach or time. Taken
#                      only when named: scripts/screenshots.sh 4-find
#                      ($SHOTS_MODES=dark redoes one mode)
#   # expect: a, b     words rate.swift checks are on screen (feature coverage)
#   # legible: <px>    rate.swift's text-height floor for this shot (default 40)
#
# compose.swift also works on its own, on captures you take by hand
# (⇧⌘4, Space, click a window — shadow included).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DOC_ROOT="${SHOTS_DOC_ROOT:-$ROOT}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
OUT="${SHOTS_OUT:-$ROOT/misc/screenshots/$VERSION}"
mkdir -p "$OUT/raw"
PATTERNS=("$@")
# --failed: the shots the last run's rating put below the bar.
[ "${PATTERNS[0]:-}" = --failed ] && read -ra PATTERNS < "$OUT/.failed"
wanted() {
    [ ${#PATTERNS[@]} -eq 0 ] && return 0
    local p; for p in "${PATTERNS[@]}"; do [[ "$1" == *$p* ]] && return 0; done
    return 1
}
BACKGROUND="${SHOTS_BACKGROUND:-$(osascript -e 'tell application "System Events" to get picture of current desktop' 2>/dev/null)}"
[ "$BACKGROUND" = none ] && BACKGROUND=""
SRC="${SHOTS_SRC:-$ROOT}"
SIZE="${SHOTS_SIZE:-}"; export SHOTS_SIZE="${SIZE:-2880x1800}"   # rate.swift checks it

echo "== building shots bundle from $SRC"
(cd "$SRC" && swift build 2>&1 | grep -E "error:|Build complete" | tail -2)
BIN="$(cd "$SRC" && swift build --show-bin-path)"
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
# Compiled once: `swift <script>` recompiles on every call, ~5 s each.
swiftc -O scripts/screenshots/compose.swift -o "$RUN/compose" 2>&1 | grep error
swiftc -O scripts/screenshots/rate.swift -o "$RUN/rate" 2>&1 | grep error

# Whole seconds since the last keyboard or mouse input.
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF / 1e9); exit}'; }

# capture <doc> <script> <raw prefix> [args...] → 0 when a key window was
# captured. Writes <prefix>-<n>.png per visible window, the key window last.
capture() {
    local doc="$1" script="$2" prefix="$3"; shift 3
    local log="$script.log"
    rm -f "$log" "$prefix"-*.png
    # Factory settings every run: the toolbar layout, window frame and panes
    # one shot leaves behind would otherwise show up in the next.
    defaults delete com.i7t5.edmund.shots >/dev/null 2>&1
    # The shot takes the key window: keys typed elsewhere meanwhile land in the
    # document (title "Edited", stray letters). Wait for 3 s of no input.
    until [ "$(idle)" -ge 3 ]; do sleep 0.5; done
    local started=$SECONDS
    # Through LaunchServices, not exec: macOS lets an app it launched take
    # activation, while an exec'd binary's `front` is refused whenever
    # someone is using another app.
    open -n "$ROOT/$APP" --args "$doc" -debug.reproScript "$script" \
        -debug.disableUpdater YES -NSAppSleepDisabled YES -ApplePersistenceIgnoreState YES \
        -EditorTypewriterMode NO -NSTextInsertionPointBlinkPeriodOn 100000 -NSTextInsertionPointBlinkPeriodOff 1 \
        -AppleShowScrollBars WhenScrolling "$@"
    local pid="" got=1
    for _ in $(seq 1 50); do
        pid="$(pgrep -n -f "$ROOT/$APP/Contents/MacOS/edmd")" && break
        sleep 0.1
    done
    for _ in $(seq 1 600); do
        kill -0 "$pid" 2>/dev/null || break
        if grep -q '^repro window ' "$log" 2>/dev/null; then
            sleep 0.2   # every window's line is in
            if [ -n "${GO:-}" ]; then
                # A manual shot: the maintainer sets it up and takes it (⇧⌘4,
                # Space, click — timing-sensitive states like find's yellow
                # highlight need their hand), and the first new PNG in the
                # screenshot folder is it. Or they `touch $GO` and this takes it.
                local folder new
                folder="$(defaults read com.apple.screencapture location 2>/dev/null || echo "$HOME/Desktop")"
                folder="${folder/#\~/$HOME}"
                rm -f "$GO"; touch "$GO.since"
                echo "      waiting: $MANUAL — then ⇧⌘4, Space, click the window (or: touch '$GO')"
                until [ -e "$GO" ] || new="$(find "$folder" -maxdepth 1 -name '*.png' -newer "$GO.since" | head -1)" && [ -n "$new" ]; do
                    kill -0 "$pid" 2>/dev/null || { echo "      the app quit before the shot"; return 2; }
                    sleep 0.3
                done
                if [ -n "${new:-}" ]; then
                    sleep 0.5   # screencapture finishes writing
                    cp "$new" "$prefix-1.png"; echo "      took $new"
                else
                    local n=0 wid
                    for wid in $(grep '^repro window ' "$log" | awk '{print $3}'); do
                        n=$((n + 1))
                        screencapture -x -l "$wid" "$prefix-$n.png"
                    done
                fi
                rm -f "$GO" "$GO.since"
                got=0
            elif [ "$(idle)" -lt $((SECONDS - started)) ]; then
                echo "      input during the shot; discarded"   # it may have landed in the doc
            elif grep -q '^repro window .* key=true' "$log"; then
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
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
    return $got
}

header() { sed -n "s/^# $2: *//p" "$1" | head -1; }

# A named combined shot brings its parts with it, and a named part the
# combined shots built from it: only what's named is captured again.
for shot in scripts/screenshots/*.shot; do
    name="$(basename "$shot" .shot)"
    for part in $(header "$shot" combine); do
        part="${part%@*}"
        if wanted "$name" && ! wanted "$part"; then PATTERNS+=("$part")
        elif wanted "$part" && ! wanted "$name"; then PATTERNS+=("$name"); fi
    done
done

shots=0; failed=(); made=()
for shot in scripts/screenshots/*.shot; do
    name="$(basename "$shot" .shot)"
    wanted "$name" || continue
    [ -n "$(header "$shot" combine)" ] && continue   # composed below
    doc="$DOC_ROOT/$(header "$shot" doc)"
    modes="${SHOTS_MODES:-$(header "$shot" modes)}"
    size="$(header "$shot" window)"
    offset="$(header "$shot" offset)"; layout="$(header "$shot" layout)"; scale="$(header "$shot" scale)"
    eval "set -- $(header "$shot" args)"
    MANUAL="$(header "$shot" manual)"
    # Manual shots wait for a person, so only a run that names them takes them.
    [[ -n "$MANUAL" && ${#PATTERNS[@]} -eq 0 ]] && { echo "skip  $name (manual: scripts/screenshots.sh $name)"; continue; }
    if [ ! -f "$doc" ]; then
        echo "FAIL  $name  (doc missing: $doc)"; failed+=("$name"); continue
    fi
    src="$doc"; doc="$RUN/$name-docs/$(basename "$src")"
    for mode in ${modes:-light}; do
        script="$RUN/$name-$mode.repro"
        # `front` first, so a window the scenario opens (Settings) ends up key,
        # and before the resize: it can move the window to the screen in use,
        # and the resize moves it back to a Retina one.
        # Every document shows from its top: a caret move can scroll the editor.
        # The waits are short to keep the screen takeover short; a shot that
        # renders asynchronously (Mermaid, Read mode) sleeps on its own.
        { printf '%s\n' front 'sleep 300' "resizewindow ${size:-960,600}" 'sleep 300'; grep -v '^#' "$shot"
          printf '%s\n' 'sleep 300' 'scroll top' 'readscroll 0'
          # Ask for focus again right before the shot: cheaper than a relaunch
          # when macOS refused the first `front`. Not over a Settings window.
          grep -q '^settingspane' "$shot" || printf '%s\n' front
          # A manual shot waits up to a day for its person; `done` quits the app.
          if [ -n "$MANUAL" ]; then printf '%s\n' logwindows 'sleep 86400000' done
          else printf '%s\n' 'sleep 700' logwindows 'sleep 1500' done; fi; } > "$script"
        raw="$OUT/raw/$name-$mode"
        GO=""; [ -n "$MANUAL" ] && GO="$OUT/raw/$name-$mode.go"
        ok=""
        for attempt in 1 2 3 4 5; do
            # Documents autosave in place: each attempt opens a fresh copy of
            # the doc's folder (images too), so a discarded one's stray keys
            # don't carry over.
            rm -rf "$RUN/$name-docs"; cp -R "$(dirname "$src")" "$RUN/$name-docs"
            capture "$doc" "$script" "$raw" -settings.appearance.mode "$mode" "$@"
            case $? in 0) ok=1; break ;; 2) break ;; esac
            echo "      $name-$mode: no clean shot (attempt $attempt), retrying"
        done
        if [ -z "$ok" ]; then
            echo "FAIL  $name-$mode"; failed+=("$name-$mode"); continue
        fi
        if [ "$(header "$shot" compose)" = no ]; then
            echo "ok    $name-$mode (raw only)"; continue
        fi
        "$RUN/compose" "$OUT/$name-$mode.png" "$mode" ${SIZE:+--size "$SIZE"} \
            ${offset:+--offset "$offset"} ${layout:+--layout "$layout"} ${scale:+--scale "$scale"} ${BACKGROUND:+--background "$BACKGROUND"} "$raw"-*.png
        echo "ok    $name-$mode"
        shots=$((shots + 1)); made+=("$OUT/$name-$mode.png")
    done
done

# Combined shots: the key window of each listed shot (its last raw capture),
# in order, on one canvas. Runs after the captures, from whatever raw/ holds.
for shot in scripts/screenshots/*.shot; do
    name="$(basename "$shot" .shot)"
    wanted "$name" || continue
    parts="$(header "$shot" combine)"
    [ -n "$parts" ] || continue
    offset="$(header "$shot" offset)"; layout="$(header "$shot" layout)"; scale="$(header "$shot" scale)"
    modes="$(header "$shot" modes)"
    for mode in ${modes:-light}; do
        windows=()
        for part in $parts; do
            # <shot>@<mode> pins a part's mode: a light and a dark window together.
            pmode="${part#*@}"; [ "$pmode" = "$part" ] && pmode="$mode"
            last="$(ls "$OUT/raw/${part%@*}-$pmode"-*.png 2>/dev/null | tail -1)"
            [ -n "$last" ] || { echo "FAIL  $name-$mode  (no capture of $part)"; failed+=("$name-$mode"); continue 2; }
            windows+=("$last")
        done
        "$RUN/compose" "$OUT/$name-$mode.png" "$mode" ${SIZE:+--size "$SIZE"} \
            ${offset:+--offset "$offset"} ${layout:+--layout "$layout"} ${scale:+--scale "$scale"} ${BACKGROUND:+--background "$BACKGROUND"} "${windows[@]}"
        echo "ok    $name-$mode (combined)"
        shots=$((shots + 1)); made+=("$OUT/$name-$mode.png")
    done
done

echo ""
echo "== $shots screenshots in $OUT"
[ ${#made[@]} -gt 0 ] || exit 1
echo "== ratings (scripts/screenshots/rate.swift)"
# rate.swift's last line names the shots below the bar; --failed reruns them.
"$RUN/rate" scripts/screenshots "${made[@]}" | tee "$OUT/.rating" || failed+=(rating)
sed -n 's/^below: //p' "$OUT/.rating" > "$OUT/.failed"
[ ${#failed[@]} -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
