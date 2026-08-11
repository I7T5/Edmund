#!/bin/bash
# PreToolUse(Bash): keep visual verification off the user's foreground.
#
# Why this exists: capturing a screen *rect* grabs whatever window is in front,
# which on a machine the maintainer is actively using is their browser, not
# Edmund — and the usual "fix" (osascript frontmost + keystroke) types into
# whatever has focus. Both happened in one session; the correct tools already
# existed and were simply not reached for.
#
# Capture by CGWindow id instead (works on a background window, steals nothing),
# and drive the app in-process with -debug.reproScript rather than CGEvents.
#
# Reads the hook JSON on stdin, emits a deny decision or {}.

set -uo pipefail

cmd=$(jq -r '.tool_input.command // empty')
[[ -n "$cmd" ]] || { echo '{}'; exit 0; }

deny() {
  jq -nc --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# `screencapture -R x,y,w,h` / `-Rx,y,w,h` — a screen rect, not a window.
if grep -Eq '(^|[;&|[:space:]])screencapture([[:space:]]+-[^[:space:]]+)*[[:space:]]+-R' <<<"$cmd"; then
  deny 'screencapture -R captures a screen rect — it grabs whatever window is frontmost, which is the user'\''s app when they are at the machine (this has produced screenshots of the maintainer'\''s browser and terminal). Capture the Edmund window by CGWindow id instead, which works even when the window is behind and steals no focus:
  .claude/skills/edmund-live-repro-and-diagnostics/scripts/ui-harness.sh capture out.png
  (or capture-window.sh / winid.swift in the same directory; ARCHITECTURE §8 "Running & verifying the app").
Full-screen `screencapture out.png` with no -R is not blocked.'
fi

# System Events keystroke / key code / frontmost — types into whatever has focus.
if grep -q 'System Events' <<<"$cmd" &&
   grep -Eq 'keystroke|key code|set frontmost' <<<"$cmd"; then
  deny 'Synthesizing keystrokes through System Events types into whatever app currently has focus, and raising Edmund pulls the user out of what they were doing. Drive the running app in-process instead:
  edmd file.md -debug.reproScript script.txt   # caret / type / backspace / scroll / viewmode
See Sources/edmd/App/ReproScript.swift for the command list and the live-repro skill for the escalation ladder. If a real CGEvent path is genuinely required, ask the user first — they may be at the keyboard.'
fi

# The same steal, one level down. `ui-harness.sh raise` (and open-find /
# replace / shot, which all call cmd_raise) runs `set frontmost` *inside the
# script*, so the check above only ever sees the word "ui-harness.sh" and waves
# it through. This gap let an agent foreground the app repeatedly while the
# maintainer was working, which is the exact thing this file exists to stop.
# Match the subcommand, not the osascript it hides.
if grep -Eq 'ui-harness\.sh[[:space:]]+(raise|open-find|replace|shot)\b' <<<"$cmd"; then
  deny 'ui-harness.sh raise / open-find / replace / shot all activate Edmund and pull the maintainer out of what they were doing — the osascript is inside the script, which is why the System Events rule above does not catch it.
Capture instead, which works on a background window and steals nothing:
  ui-harness.sh capture out.png          # or capture-window.sh <title> out.png
To reach a bar or a control without focus, relaunch with the state you need and drive the app in-process:
  open -g -n build/EdmundDbg.app --args file.md -settings.edit.showFormatBar NO
  edmd file.md -debug.reproScript script.txt
`open -g` starts the app in the background; launching the bare binary foregrounds it. If you truly need the app frontmost, ask the maintainer first — they may be at the keyboard.'
fi

echo '{}'
