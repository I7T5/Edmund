#!/bin/bash
# PreToolUse guard: docs/CHANGELOG.md is written in the maintainer's words,
# only from /release, and only with their say-so.
#
# Release notes reach users verbatim (GitHub Release body, Sparkle's update
# dialog), so they stay in the maintainer's voice. /release may write the
# section — after asking the maintainer for their wording and for each change
# it wants to make (.claude/commands/release.md). This hook allows an Edit or
# Write only while the maintainer's latest message is a /release invocation
# (`from_release`), and even then stops for their confirmation ("ask"), so an
# agent can't slip an edit in without them seeing the diff. Any other time it
# is denied.
#
# Only the file-editing tools may write it, and each one asks. Shell paths to
# the same file (redirects, sed -i, tee, cp/mv onto it) stay denied: they'd
# bypass the reviewable diff. A determined script can still get there; this is
# a guardrail against habit, not a sandbox.

set -euo pipefail
input="$(cat)"

decide() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}' \
        "$1" "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    exit 0
}

ASK="Writing docs/CHANGELOG.md — the release notes users see verbatim. \
Approve only wording the maintainer has already agreed to in this chat \
(.claude/commands/release.md)."

DENY="docs/CHANGELOG.md is written only through the Edit/Write tools, which \
ask the maintainer to confirm the diff — not from the shell. \
See .claude/commands/release.md."

ONLY_RELEASE="docs/CHANGELOG.md is edited only from /release, which asks for \
the maintainer's wording and each change first. Propose the change instead, or \
ask the maintainer to run /release <version>."

# Whether the maintainer's latest message is a /release invocation. Their typed
# messages are the transcript's user entries that aren't isMeta and hold a
# plain string; a slash command they type is logged as one of those, starting
# with <command-message>release</command-message>. Skills an agent invokes
# itself, tool results and subagent reports are never such entries, so an agent
# can't unlock the file on its own. No transcript, or anything unreadable → no.
from_release() {
    local transcript
    transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
    [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
    [ "$(jq -s '[.[] | select(.type == "user" and (.isMeta != true)
                              and (.message.content | type) == "string")]
                | last | (.message.content // "")
                | test("^<command-message>release</command-message>")' \
            "$transcript" 2>/dev/null)" = "true" ]
}

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

case "$tool" in
    Edit|Write|NotebookEdit|MultiEdit)
        path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
        case "$path" in
            */docs/CHANGELOG.md|docs/CHANGELOG.md)
                if from_release; then decide ask "$ASK"; else decide deny "$ONLY_RELEASE"; fi ;;
        esac
        ;;
    Bash)
        cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
        # Writes only. Reading it stays allowed (cat/grep/awk/head), including
        # scripts/release.sh, which pulls the release notes out of it — so the
        # file has to be named *and* the command has to be a writing one. An
        # in-place editor names its file last, hence the two separate tests.
        printf '%s' "$cmd" | grep -q 'docs/CHANGELOG\.md' || { echo '{}'; exit 0; }
        # Redirection into the file itself (`> docs/CHANGELOG.md`).
        if printf '%s' "$cmd" | grep -Eq '>>?[[:space:]]*([^[:space:]]*/)?docs/CHANGELOG\.md'; then
            decide deny "$DENY"
        fi
        # A copy, a move, or an in-place edit anywhere in the command.
        if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]|&;(])(tee|cp|mv|install|truncate|dd)([[:space:]]|$)'; then
            decide deny "$DENY"
        fi
        if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]|&;(])(sed|perl|ruby|python[0-9.]*|awk)[[:space:]][^|]*(-i|--in-place)'; then
            decide deny "$DENY"
        fi
        ;;
esac

echo '{}'
