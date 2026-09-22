#!/bin/bash
# PreToolUse guard: docs/CHANGELOG.md is written in the maintainer's words,
# and only with their say-so.
#
# Release notes reach users verbatim (GitHub Release body, Sparkle's update
# dialog), so they stay in the maintainer's voice. /release may write the
# section — after asking the maintainer for their wording and for each change
# it wants to make (.claude/commands/release.md) — and this hook makes every
# such write stop for the maintainer's confirmation ("ask"), so an agent can't
# slip an edit in without them seeing the diff.
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

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

case "$tool" in
    Edit|Write|NotebookEdit|MultiEdit)
        path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
        case "$path" in
            */docs/CHANGELOG.md|docs/CHANGELOG.md) decide ask "$ASK" ;;
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
