#!/bin/bash
# README, site and App Store preview recordings of the real app: the video
# twin of scripts/screenshots.sh, whose header documents the shared parts.
#
# Usage: scripts/recordings.sh [pattern...]   e.g. scripts/recordings.sh live-preview
#        scripts/recordings.sh --failed       the clips the last rating put below the bar
#        scripts/recordings.sh --compose-only [pattern...]
#                                             re-encode from raw/ without launching the app
# The App Review recording (launch to quit, performed by hand) is
# scripts/review-recording.sh.
#
# Each scripts/recordings/<name>.rec is a ReproScript scenario. Lines above a
# `# --- record ---` line set the window up off camera; the lines below it are
# filmed. Headers, as in .shot files: # doc:, # args:, # modes:, # window:,
# # scale:, # expect:, # legible:, # alt:. And:
#   # length: <ms>     how long to film, from the marker (required)
#   # appstore: yes    also render the App Store app preview (1920×1080)
#   # blank: <name>    start from a new empty file of that name, not # doc:
#   # loop: yes        the last 0.7 s fade into the first frame, so the clip
#                      ends as it began; rate.swift checks it does
#   # cuts: <n>        cuts on purpose (⌘E to Read mode), not held against it
#   # poster: <ms>     the poster frame's time in the clip, for a clip whose
#                      end isn't its result (default: the held result at the end)
#   # typing: human [seed] [wpm]  type the filmed lines with a person's rhythm:
#                      the human-typing skill's humantype ($HUMANTYPE, default
#                      ~/.claude/skills/human-typing/humantype.swift) expands
#                      each `type` line key by key; same seed, same take
# {root} in a command is $SHOTS_DOC_ROOT: `pasteimage {root}/misc/…/photo.jpg`.
#   # combine: <rec>...  no run of its own: the App Store previews of those clips
#                      back to back, for the preview's 15–30 s
#
# The app films its own window (ReproScript `record`: ScreenCaptureKit,
# shadow included), so other windows may cover it while it records. It
# still has to be the active app, or the traffic lights record grey: each
# clip waits for 3 s with no keyboard or mouse input, and input during the
# clip discards it (up to 5 attempts). Keys typed meanwhile land in Edmund.
#
# Screen Recording: the bundle is signed with the Apple Development identity,
# so the grant System Settings records for it survives rebuilds. First run:
# Privacy & Security ▸ Screen & System Audio Recording ▸ allow edmd.
#
# Output: $REC_OUT (default misc/recordings/<version>/):
#   raw/<name>-<mode>/NNNN-<ms>.png  every frame the window drew, with shadow
#   <name>-<mode>.mp4                site clip, 1440×900, H.264
#   <name>-<mode>-appstore.mp4       App Store preview, 1920×1080, 30 fps, silent audio
#   <name>-<mode>.gif                with REC_GIF=1, 960 wide
#   <name>-<mode>-poster.png         the last frame, for a <video poster>
#   <name>-<mode>-sheet.png          rate.swift's contact sheet
# $SHOTS_BACKGROUND, $SHOTS_SRC and $SHOTS_DOC_ROOT work as in screenshots.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DOC_ROOT="${SHOTS_DOC_ROOT:-$ROOT}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
OUT="${REC_OUT:-$ROOT/misc/recordings/$VERSION}"
mkdir -p "$OUT/raw"
COMPOSE_ONLY=""
[ "${1:-}" = --compose-only ] && { COMPOSE_ONLY=1; shift; }
PATTERNS=("$@")
[ "${PATTERNS[0]:-}" = --failed ] && read -ra PATTERNS < "$OUT/.failed"
wanted() {
    [ ${#PATTERNS[@]} -eq 0 ] && return 0
    local p; for p in "${PATTERNS[@]}"; do [[ "$1" == *$p* ]] && return 0; done
    return 1
}
BACKGROUND="${SHOTS_BACKGROUND:-$(osascript -e 'tell application "System Events" to get picture of current desktop' 2>/dev/null)}"
[ "$BACKGROUND" = none ] && BACKGROUND=""
SRC="${SHOTS_SRC:-$ROOT}"
ID=com.i7t5.edmund.recordings

# ponytail: the bundle block is screenshots.sh's, plus signing; share it when
# a third script needs it.
APP="build/EdmundRecordings.app"
if [ -z "$COMPOSE_ONLY" ]; then
    echo "== building recordings bundle from $SRC"
    # Optimized, with the DEBUG-only ReproScript driver: a debug build's
    # restyle per key outlasts the gap between keys, so typing falls seconds
    # behind its script. Own scratch path: build-app.sh's release builds have
    # no driver, and sharing would rebuild everything each switch.
    build=(swift build -c release -Xswiftc -DDEBUG --scratch-path .build/recordings)
    (cd "$SRC" && "${build[@]}" 2>&1 | grep -E "error:|Build complete" | tail -2)
    BIN="$(cd "$SRC" && "${build[@]}" --show-bin-path)"
    rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp Info.plist "$APP/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string $ID "$APP/Contents/Info.plist"
    cp "$BIN/edmd" "$APP/Contents/MacOS/edmd"
    [ -d "$BIN/Sparkle.framework" ] && cp -R "$BIN/Sparkle.framework" "$APP/Contents/MacOS/"
    # In Resources, not the bundle root: codesign won't seal a bundle with
    # loose files at its root (build-app.sh has the same rule).
    for bundle in "$BIN"/*.bundle; do [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"; done
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
    cp -R Resources/Edmund.help "$APP/Contents/Resources/"
    xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
        --minimum-deployment-target 14.0 --output-partial-info-plist "$(mktemp)" >/dev/null
    # A stable signature keeps the Screen Recording grant across rebuilds; an
    # ad-hoc one changes with every build and loses it.
    codesign --force --deep --sign "Apple Development" "$APP" 2>&1 | grep -v "replacing existing signature"
fi

RUN="$(mktemp -d)"
HUMANTYPE="${HUMANTYPE:-$HOME/.claude/skills/human-typing/humantype.swift}"
swiftc -O scripts/screenshots/compose.swift -o "$RUN/compose" 2>&1 | grep error
swiftc -O scripts/recordings/rate.swift -o "$RUN/rate" 2>&1 | grep error

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF / 1e9); exit}'; }
header() { sed -n "s/^# $2: *//p" "$1" | head -1; }

# film <doc> <script> <raw dir> <length ms> [args...] → 0 filmed, 1 retry, 2 give up.
film() {
    local doc="$1" script="$2" raw="$3" length="$4"; shift 4
    local log="$script.log" plate="$raw-plate.png" wid
    rm -rf "$log" "$raw" "$plate"
    defaults delete $ID >/dev/null 2>&1
    until [ "$(idle)" -ge 3 ]; do sleep 0.5; done
    local started=$SECONDS
    open -n "$ROOT/$APP" --args "$doc" -debug.reproScript "$script" \
        -debug.disableUpdater YES -NSAppSleepDisabled YES -ApplePersistenceIgnoreState YES \
        -EditorTypewriterMode NO -NSTextInsertionPointBlinkPeriodOn 100000 -NSTextInsertionPointBlinkPeriodOff 1 \
        -AppleShowScrollBars WhenScrolling "$@"
    local pid="" got=1
    for _ in $(seq 1 50); do
        pid="$(pgrep -n -f "$ROOT/$APP/Contents/MacOS/edmd")" && break
        sleep 0.1
    done
    # The app's own start-up (1.5 s), the setup, then the clip.
    for _ in $(seq 1 $((length / 100 + 600))); do
        kill -0 "$pid" 2>/dev/null || { echo "      the app quit"; break; }
        # The shadow plate: one still of the key window, shadow and alpha as
        # screencapture takes them (the stream's shadow is on opaque black).
        # Only its shadow, corners and outline are used, so any moment will do.
        if [ ! -f "$plate" ] && grep -q '^repro window .* key=true' "$log" 2>/dev/null; then
            wid="$(grep '^repro window .* key=true' "$log" | awk '{print $3}' | tail -1)"
            screencapture -x -l "$wid" "$plate"
        fi
        if grep -q 'declined TCC' "$log" 2>/dev/null; then
            echo "      Screen Recording is off for $ID: System Settings ▸ Privacy & Security ▸"
            echo "      Screen & System Audio Recording ▸ allow edmd ($ROOT/$APP), then rerun"
            got=2; break
        elif grep -q '^repro record error' "$log" 2>/dev/null; then
            grep '^repro record error' "$log" | sed 's/^/      /'; break
        elif grep -q '^repro record done' "$log" 2>/dev/null; then
            if [ "$(idle)" -lt $((SECONDS - started)) ]; then
                echo "      input during the clip; discarded"
            elif ! grep -q '^repro window .* key=true' "$log"; then
                echo "      Edmund wasn't active (grey traffic lights); discarded"
            elif [ "$(ls "$raw" 2>/dev/null | wc -l)" -lt 2 ]; then
                echo "      no frames"
            elif [ ! -f "$plate" ]; then
                echo "      no shadow plate"
            else
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

# encode <raw dir> <out.mp4> <WxH> <mode> <length ms> <scale> [audio]
# The frames, timed as the window drew them, centred on compose.swift's
# background at the size and scale a screenshot would get; 30 fps constant.
encode() {
    local raw="$1" out="$2" size="$3" mode="$4" length="$5" scale="$6" audio="${7:-}"
    local first wh list="$RUN/frames.txt" bg="$RUN/bg.png" clear="$RUN/clear.png" plate="$raw-plate.png"
    dims() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }
    first="$(ls "$raw"/*.png | head -1)"
    wh="$(dims "$first")"
    # record crops to screencapture's shadow margins, so the two line up.
    [ "$(dims "$plate")" = "$wh" ] || { echo "      plate $(dims "$plate") ≠ frames $wh"; return 1; }
    ffmpeg -v error -y -f lavfi -i "color=c=black@0:s=$wh,format=rgba" -frames:v 1 "$clear"
    # compose.swift on a clear window of the frame's size: the background,
    # and the scale it would draw the window at.
    local s
    s="$("$RUN/compose" "$bg" "$mode" --size "$size" ${scale:+--scale "$scale"} \
        ${BACKGROUND:+--background "$BACKGROUND"} "$clear" | sed -n 's/^scale //p')"
    # Concat list: each frame lasts until the next; the last until <length>
    # after the first (concat ignores the last entry's duration, so it repeats).
    ls "$raw"/*.png | awk -F/ -v len="$length" '
        { n = $NF; sub(/\.png$/, "", n); sub(/^[0-9]+-/, "", n); ms[NR] = n; f[NR] = $0 }
        END { for (i = 1; i <= NR; i++) {
                  d = (i < NR ? ms[i + 1] : ms[1] + len) - ms[i]; if (d < 1) d = 1
                  printf "file '\''%s'\''\nduration %.3f\n", f[i], d / 1000 }
              printf "file '\''%s'\''\n", f[NR] }' > "$list"
    local a=() m=()
    [ -n "$audio" ] && { a=(-f lavfi -i anullsrc=r=48000:cl=stereo); m=(-map 3:a -c:a aac -b:a 128k -shortest); }
    # The window: each frame inside the plate's opaque outline (alpha from the
    # plate), laid on the plate for its shadow and rounded corners; then
    # scaled and centred on the background. -t ends it: the looped plate
    # keeps alphamerge from ever reaching the end.
    # ${x[@]+…}: bash 3.2 calls an empty array unbound under set -u.
    ffmpeg -v error -y -loop 1 -i "$bg" -f concat -safe 0 -i "$list" -loop 1 -framerate 60 -i "$plate" \
        ${a[@]+"${a[@]}"} -filter_complex \
        "[2:v]format=rgba,split[p][pm];[pm]alphaextract,lut=y='if(gte(val,250),255,0)'[m];
         [1:v]format=rgb24[f];[f][m]alphamerge[fa];[p][fa]overlay=0:0:shortest=1[pw];
         [pw]scale=iw*$s:ih*$s:flags=lanczos[w];[0:v][w]overlay=(W-w)/2:(H-h)/2:shortest=1,fps=30,format=yuv420p[v]" \
        -map "[v]" ${m[@]+"${m[@]}"} -t "$(echo "scale=3; $length / 1000" | bc)" -c:v libx264 -preset slow -crf 18 -profile:v high -movflags +faststart -r 30 "$out" || return 1
    [ "$LOOP" = yes ] || return 0
    # Loop: a 0.6 s fade into the first frame, then 0.1 s of it (xfade's last
    # frame stops short of the end), so the clip ends exactly where it starts
    # and a looping player shows no jump. Same length; audio kept.
    ffmpeg -v error -y -i "$out" -frames:v 1 -update 1 "$RUN/first.png" &&
    ffmpeg -v error -y -i "$out" -loop 1 -framerate 30 -t 0.7 -i "$RUN/first.png" -filter_complex \
        "[0:v]settb=AVTB,fps=30[a];[1:v]settb=AVTB,fps=30,format=yuv420p[b];[a][b]xfade=transition=fade:duration=0.6:offset=$(echo "scale=3; $length / 1000 - 0.7" | bc),format=yuv420p[v]" \
        -map "[v]" -map '0:a?' -c:a copy -c:v libx264 -preset slow -crf 18 -profile:v high -movflags +faststart -r 30 "$RUN/loop.mp4" &&
    mv "$RUN/loop.mp4" "$out"
}

# Filming takes the screen and discards a clip on any input, so ask first,
# as /verify-live's live-verifier does (same alert, same wording rules: a
# question for the title, the action on the button, Cancel the default so a
# stray Return starts nothing). About 15 s a clip besides its length:
# launch, setup, the 3 s with no input; the upper bound allows a retry each.
if [ -z "$COMPOSE_ONLY" ]; then
    ms=0
    for rec in scripts/recordings/*.rec; do
        wanted "$(basename "$rec" .rec)" && [ -z "$(header "$rec" combine)" ] || continue
        modes=(${SHOTS_MODES:-$(header "$rec" modes)})
        ms=$(( ms + ${#modes[@]} * ($(header "$rec" length) + 15000) ))
    done
    a=$(( (ms + 59999) / 60000 )); b=$(( a * 2 ))
    answer="$(osascript -e "display dialog \"An Edmund window will open on your desktop and come to the front. A key press or click during a clip films it again, so please don't touch the mouse or keyboard.\n\nThis takes about $a to $b minutes. Edmund opens only for the recordings and quits afterwards.\" with title \"Start the Edmund recordings?\" with icon note buttons {\"Cancel\", \"Start Recording\"} default button \"Cancel\" cancel button \"Cancel\" giving up after 180" 2>&1)"
    case "$answer" in
        *"button returned:Start Recording"*"gave up:false"*) ;;
        *) echo "== not started (${answer:-no answer})"; exit 1 ;;
    esac
fi

clips=0; failed=(); made=()
for rec in scripts/recordings/*.rec; do
    name="$(basename "$rec" .rec)"
    wanted "$name" || continue
    [ -n "$(header "$rec" combine)" ] && continue
    length="$(header "$rec" length)"; LOOP="$(header "$rec" loop)"
    [ -n "$length" ] || { echo "FAIL  $name  (no # length:)"; failed+=("$name"); continue; }
    # `# blank: <name>` starts from a new empty file of that name instead.
    blank="$(header "$rec" blank)"
    doc="$DOC_ROOT/$(header "$rec" doc)"
    size="$(header "$rec" window)"; scale="$(header "$rec" scale)"
    eval "set -- $(header "$rec" args)"
    if [ -z "$COMPOSE_ONLY$blank" ] && [ ! -f "$doc" ]; then
        echo "FAIL  $name  (doc missing: $doc)"; failed+=("$name"); continue
    fi
    src="$doc"; doc="$RUN/$name-docs/${blank:-$(basename "$src")}"
    # `# typing: human [seed] [wpm]`: the filmed `type` lines, key by key.
    read -r tmode tseed twpm <<< "$(header "$rec" typing)"
    humanize() { cat; }
    if [ "${tmode:-}" = human ]; then
        if [ ! -x "$RUN/humantype" ] && ! swiftc -O "$HUMANTYPE" -o "$RUN/humantype" 2>/dev/null; then
            echo "      no humantype at $HUMANTYPE: typing at a steady pace"
        else
            humanize() { "$RUN/humantype" expand --seed "${tseed:-1}" --wpm "${twpm:-90}" --builtin 80; }
        fi
    fi
    for mode in ${SHOTS_MODES:-$(header "$rec" modes)}; do
        raw="$OUT/raw/$name-$mode"; script="$RUN/$name-$mode.repro"
        # Set up off camera, ask for focus again, log whether the window is
        # key (traffic lights in colour), then film. The window's id and key
        # state are logged before the clip, so the check doesn't film.
        # {root} in a command stands for $SHOTS_DOC_ROOT (`pasteimage {root}/…`).
        { printf '%s\n' front 'sleep 300' "resizewindow ${size:-960,600}" 'sleep 300' 'scroll top'
          sed '/^# --- record ---/,$d' "$rec" | grep -v '^#'
          # 1 s: `front` can move the window to another screen, and the
          # stream can't find it until the move is done.
          printf '%s\n' 'sleep 300' front 'sleep 1000' logwindows "record $length,$raw"
          sed '1,/^# --- record ---/d' "$rec" | grep -v '^#' | humanize; } | sed "s|{root}|$DOC_ROOT|g" > "$script"
        ok=""
        if [ -n "$COMPOSE_ONLY" ]; then
            ls "$raw"/*.png >/dev/null 2>&1 && ok=1 || echo "      $name-$mode: nothing in raw/"
        else for attempt in 1 2 3 4 5; do
            rm -rf "$RUN/$name-docs"
            if [ -n "$blank" ]; then mkdir "$RUN/$name-docs"; : > "$doc"
            else cp -R "$(dirname "$src")" "$RUN/$name-docs"; fi
            film "$doc" "$script" "$raw" "$length" -settings.appearance.mode "$mode" "$@"
            case $? in 0) ok=1; break ;; 2) break ;; esac
            echo "      $name-$mode: no clean clip (attempt $attempt), retrying"
        done; fi
        [ -n "$ok" ] || { echo "FAIL  $name-$mode"; failed+=("$name-$mode"); continue; }
        base="$OUT/$name-$mode"
        encode "$raw" "$base.mp4" 1440x900 "$mode" "$length" "$scale" ||
            { echo "FAIL  $name-$mode (encode)"; failed+=("$name-$mode"); continue; }
        made+=("$base.mp4")
        if [ "$(header "$rec" appstore)" = yes ]; then
            encode "$raw" "$base-appstore.mp4" 1920x1080 "$mode" "$length" "$scale" audio
            made+=("$base-appstore.mp4")
        fi
        # The result, held: a loop's last frame is its first again, before the fade.
        poster=0.1; [ "$LOOP" = yes ] && poster=0.9
        at=(-sseof "-$poster"); [ -n "$(header "$rec" poster)" ] && at=(-ss "$(echo "scale=3; $(header "$rec" poster) / 1000" | bc)")
        ffmpeg -v error -y "${at[@]}" -i "$base.mp4" -frames:v 1 -update 1 "$base-poster.png"
        [ -n "${REC_GIF:-}" ] && ffmpeg -v error -y -i "$base.mp4" -vf \
            "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" "$base.gif"
        echo "ok    $name-$mode"; clips=$((clips + 1))
    done
done

# App Store previews made of clips: their -appstore.mp4s back to back.
for rec in scripts/recordings/*.rec; do
    name="$(basename "$rec" .rec)"
    wanted "$name" || continue
    parts="$(header "$rec" combine)"
    [ -n "$parts" ] || continue
    for mode in ${SHOTS_MODES:-$(header "$rec" modes)}; do
        list="$RUN/$name-$mode.txt"; : > "$list"
        for part in $parts; do
            f="$OUT/$part-$mode-appstore.mp4"
            [ -f "$f" ] || { echo "FAIL  $name-$mode  (no $f)"; failed+=("$name-$mode"); continue 2; }
            echo "file '$f'" >> "$list"
        done
        ffmpeg -v error -y -f concat -safe 0 -i "$list" -c copy -movflags +faststart "$OUT/$name-$mode-appstore.mp4"
        echo "ok    $name-$mode (combined)"; made+=("$OUT/$name-$mode-appstore.mp4"); clips=$((clips + 1))
    done
done

echo ""
echo "== $clips recordings in $OUT"
[ ${#made[@]} -gt 0 ] || exit 1
echo "== ratings (scripts/recordings/rate.swift; contact sheets: *-sheet.png)"
"$RUN/rate" scripts/recordings "${made[@]}" | tee "$OUT/.rating" || failed+=(rating)
sed -n 's/^below: //p' "$OUT/.rating" > "$OUT/.failed"
[ ${#failed[@]} -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
