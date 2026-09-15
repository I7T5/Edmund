#!/usr/bin/env bash
# ui-harness.sh — drive Edmund's UI chrome so visual work can be measured
# instead of eyeballed. Every subcommand here was executed against a live app
# while authoring (2026-07-26); none are "verify on first use".
#
#   ui-harness.sh launch <file.md> [light|dark]   # kill only OUR debug build, relaunch
#   ui-harness.sh raise                   # activate + AXRaise the document window
#   ui-harness.sh winid                   # print the document window's CGWindow id
#   ui-harness.sh state                   # closed | find | replace  (find bar state)
#   ui-harness.sh open-find               # Cmd-F, retried until `state` agrees
#   ui-harness.sh replace on|off          # toggle the Replace row via the checkbox
#   ui-harness.sh capture <out.png>       # screencapture the window by id (no focus steal)
#   ui-harness.sh shot <out.png>          # open-find + capture, one call
#
# Why each mechanism — all learned by watching the obvious version fail, so do
# not "simplify" them:
#   * Window lookup goes through winid.swift. JXA cannot do it: under osascript
#     `ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(...))` yields a value with no
#     `.length`, so the JS route silently reports nothing rather than erroring.
#   * That lookup uses .optionAll, never .optionOnScreenOnly — a freshly
#     launched app that has not been activated yet owns windows the on-screen
#     filter omits, making it look windowless.
#   * `capture` never raises. `screencapture -l<id>` grabs a background window
#     fine, and stealing focus takes the machine away from the user.
#   * Controls are clicked through Accessibility, never `click at {x,y}`:
#     System Events coordinate clicks do not reliably land on the control even
#     when the coordinates match the control's own AX frame.
#   * Our process is found by exact-matching the binary path field. Not
#     `pgrep -f "$BIN"`: that takes a REGEX, and a worktree path like
#     `feat+find-replace-in-doc` contains `+`, which silently matches nothing.
#     macOS `pgrep -a` prints bare pids with no args, so `-lf` is the flag that
#     carries the command line.
#   * `state` (AX tree) is the ground truth for "did the UI change"; screenshots
#     are for measuring, never for control flow.
#   * Light/dark is forced per-launch through `-settings.appearance.mode`
#     (NSArgumentDomain beats the stored default), NOT by flipping the system
#     appearance. Flipping the system takes the user's machine away from them,
#     and it does not even work here: the app shares the user's UserDefaults, so
#     a stored Light preference keeps it light whatever the system is doing.
#
# Env: DOC_TITLE overrides the window title to target (default: basename of the
# doc passed to `launch`, remembered under the repo's git dir).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE" && git rev-parse --show-toplevel)"
cd "$ROOT"
BIN="$ROOT/.build/debug/edmd"
# `git rev-parse --git-dir`, not "$ROOT/.git" — in a worktree .git is a *file*.
STATE_FILE="$(git rev-parse --git-dir)/edmund-ui-harness-doc"

title() {
  if [[ -n "${DOC_TITLE:-}" ]]; then echo "$DOC_TITLE"
  elif [[ -f "$STATE_FILE" ]]; then cat "$STATE_FILE"
  else echo "Untitled"; fi
}

# Our own instance only — the user's daily driver is also called `edmd`.
# awk on an exact field match, not `grep -F "$BIN"`: a grep for the path also
# matches the grep process's own command line.
our_pid() { pgrep -lf edmd 2>/dev/null | awk -v b="$BIN" '$2 == b { print $1; exit }'; }

kill_ours() {
  local pid
  while pid="$(our_pid)"; [[ -n "$pid" ]]; do kill "$pid" 2>/dev/null || break; sleep 1; done
}

require_pid() {
  local pid; pid="$(our_pid || true)"
  [[ -n "$pid" ]] || { echo "No debug edmd running; run: ui-harness.sh launch <file.md>" >&2; exit 1; }
  echo "$pid"
}

ax() {  # ax <applescript predicate applied to our process>
  local pid; pid="$(require_pid)"
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to $1" 2>&1
}

cmd_launch() {
  local doc="${1:?usage: ui-harness.sh launch <file.md> [light|dark]}"
  local mode="${2:-}"
  [[ -x "$BIN" ]] || { echo "Missing $BIN — run: swift build" >&2; exit 1; }
  kill_ours
  basename "$doc" > "$STATE_FILE"
  local args=( "$doc" )
  [[ -n "$mode" ]] && args+=( -settings.appearance.mode "$mode" )
  "$BIN" "${args[@]}" >/dev/null 2>&1 &
  sleep 4
  echo "pid=$(our_pid)${mode:+ appearance=$mode}"
}

cmd_raise() {
  local pid; pid="$(require_pid)"
  osascript >/dev/null 2>&1 <<AS || true
tell application "System Events"
  tell (first process whose unix id is $pid)
    set frontmost to true
    try
      perform action "AXRaise" of (first window whose title is "$(title)")
    end try
  end tell
end tell
AS
  sleep 1
}

cmd_winid() {
  local pid; pid="$(require_pid)"
  swift "$HERE/winid.swift" "$pid" "$(title)"
}

# closed | find | replace — counted off the AX tree, the only reliable signal.
#
# Two traps: (1) System Events cannot enumerate a process's windows until the
# app has been activated at least once, so this reads `closed` on a
# just-launched app — `open-find` raises first, which fixes it. (2) The failure
# mode is an *error string*, and AppleScript error text starts with a line
# number ("87:129: execution error…"), so a substring/glob test happily reads
# it as a count. Only a strict all-digits match is safe.
cmd_state() {
  local n; n="$(ax "get count of text fields of window \"$(title)\"" || true)"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    (( n >= 2 )) && echo replace || { (( n == 1 )) && echo find || echo closed; }
  else
    echo closed
  fi
}

cmd_open_find() {
  cmd_raise   # also makes the window AX-visible for the first time
  for _ in 1 2 3; do
    [[ "$(cmd_state)" == closed ]] || break
    cmd_raise
    osascript -e 'tell application "System Events" to keystroke "f" using command down' >/dev/null 2>&1
    sleep 2
  done
  cmd_state
}

cmd_replace() {
  local want="${1:?usage: ui-harness.sh replace on|off}" now
  now="$(cmd_open_find)"
  if { [[ "$want" == on ]] && [[ "$now" == find ]]; } ||
     { [[ "$want" == off ]] && [[ "$now" == replace ]]; }; then
    ax "click (checkbox 1 of window \"$(title)\")" >/dev/null || true
    sleep 2
  fi
  cmd_state
}

cmd_capture() {
  local out="${1:?usage: ui-harness.sh capture <out.png>}" id
  id="$(cmd_winid)"
  [[ -n "$id" ]] || { echo "No window id for \"$(title)\"" >&2; exit 1; }
  screencapture -x -o -l"$id" "$out"
  echo "$out"
}

cmd_shot() {
  local out="${1:?usage: ui-harness.sh shot <out.png>}"
  cmd_open_find >/dev/null
  cmd_capture "$out"
}

case "${1:?see header for usage}" in
  launch)     shift; cmd_launch "$@" ;;
  raise)      cmd_raise ;;
  winid)      cmd_winid ;;
  state)      cmd_state ;;
  open-find)  cmd_open_find ;;
  replace)    shift; cmd_replace "$@" ;;
  capture)    shift; cmd_capture "$@" ;;
  shot)       shift; cmd_shot "$@" ;;
  *) echo "Unknown subcommand: $1 (see header)" >&2; exit 64 ;;
esac
