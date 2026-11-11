#!/bin/bash
# The screen recording App Review asks for: the app launched on camera, then
# its typical flow, on a physical Mac. You perform it; this script clears the
# stage, films the whole display (pointer and clicks shown), stops when you
# quit Edmund, and rates the result (scripts/recordings/rate.swift --review).
#
# Usage: scripts/review-recording.sh [Edmund.app]   default /Applications/Edmund.app
#        REVIEW_MARKERS=Save,Open,...                 words the flow must show
#
# App Review also wants account sign-up, log-in and deletion, user-generated
# content reporting and blocking, and paid content, where an app has them.
# Edmund has none, so the flow is the editor's own; it shows the sandbox's
# Save and Open panels and the extension download (network use, the 2.5.2
# exception in Resources/Edmund.entitlements).
#
# Output: misc/recordings/<version>/app-review.mp4 (1080p, H.264) and its
# contact sheet. The full-resolution .mov is deleted once encoded.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-/Applications/Edmund.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
OUT="${REC_OUT:-$PWD/misc/recordings/$VERSION}"
mkdir -p "$OUT"
RUN="$(mktemp -d)"
MOV="$RUN/app-review.mov"; FIFO="$RUN/stop"

[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }
# The user's own Edmund is also edmd: never kill it, ask.
if pgrep -xq edmd; then echo "Edmund is running. Quit it first: the recording starts with its launch."; exit 1; fi
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] &&
    echo "note: $APP has Sparkle, so it isn't the Mac App Store build App Review gets"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)). App Review asks for the latest release."
swiftc -O scripts/recordings/rate.swift -o "$RUN/rate" 2>&1 | grep error &

cat <<'EOF'

Before you start: turn on Do Not Disturb (notifications must not show), close
anything personal, hide desktop icons if they're busy. Other apps get hidden
when the recording starts and come back after.

The flow, about 1–3 minutes, at an easy pace:
  1. Launch Edmund from the Dock or Applications (the clip has to start here).
  2. File ▸ New. Type a heading, some **bold**, a list and a small table: it
     renders as you type.
  3. File ▸ Save: the Save panel, name it, save.
  4. File ▸ Open an existing Markdown file through the Open panel.
  5. ⌘E to Read mode and back.
  6. Settings: download the Math extension, then type $x^2$ in a document.
  7. File ▸ Print… (cancel), or Export.
  8. Quit Edmund (⌘Q). The recording stops a moment later.
Ctrl-C here stops it early.

EOF
read -rp "Press Return to start (3 s countdown)… " _

# Hide every other visible app (Terminal too: it isn't part of the flow) and
# remember which, to bring them back after.
HIDDEN="$(osascript -e 'tell application "System Events"
    set names to name of every process whose visible is true and name is not "Finder"
    repeat with n in names
        set visible of process n to false
    end repeat
    set AppleScript'"'"'s text item delimiters to linefeed
    return names as text
end tell')"
unhide() {
    local n
    while IFS= read -r n; do
        [ -n "$n" ] && osascript -e "tell application \"System Events\" to set visible of process \"$n\" to true" 2>/dev/null
    done <<< "$HIDDEN"
}
for i in 3 2 1; do printf '%s… ' $i; sleep 1; done; echo

# screencapture -v stops on a key from stdin; a FIFO held open is that stdin.
mkfifo "$FIFO"
screencapture -v -C -k -x -D1 "$MOV" < "$FIFO" > /dev/null 2>&1 &
REC=$!
exec 3> "$FIFO"
stop() {
    printf 'q' >&3 2>/dev/null; exec 3>&-
    while kill -0 $REC 2>/dev/null; do sleep 0.2; done
}
trap 'echo; echo "stopped early"; stop; unhide; exit 1' INT

# Recording until Edmund has launched and quit.
until pgrep -f "$APP/Contents/MacOS/" >/dev/null; do sleep 0.3; done
echo "Edmund launched"
while pgrep -f "$APP/Contents/MacOS/" >/dev/null; do sleep 0.3; done
sleep 1.5   # the desktop after quitting closes the flow
stop; trap - INT
unhide
echo "recorded $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MOV" | cut -d. -f1) s"

ffmpeg -v error -y -i "$MOV" -vf "scale=-2:1080:flags=lanczos,fps=30,format=yuv420p" \
    -c:v libx264 -preset medium -crf 20 -an -movflags +faststart "$OUT/app-review.mp4" &&
    rm -f "$MOV"
wait
echo "== $OUT/app-review.mp4"
"$RUN/rate" --review "$OUT/app-review.mp4" ${REVIEW_MARKERS:+"$REVIEW_MARKERS"}
