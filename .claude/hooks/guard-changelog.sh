#!/bin/bash
# PreToolUse guard: docs/CHANGELOG.md is the maintainer's, never an agent's.
#
# Release notes reach users verbatim (GitHub Release body, Sparkle's update
# dialog), so they stay in the maintainer's voice. Agents collect proposed
# entries in misc/changelog-tmp — untracked scratch, one per worktree — and the
# maintainer moves what they want into docs/CHANGELOG.md themselves.
#
# Covers the file-editing tools and the obvious shell paths to the same file
# (redirects, sed -i, tee, cp/mv onto it). A determined script can still get
# there; this is a guardrail against habit, not a sandbox.

set -euo pipefail
input="$(cat)"

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' \
        "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    exit 0
}

REASON="docs/CHANGELOG.md is the maintainer's file — agents never write it. \
Put proposed entries in misc/changelog-tmp (untracked) and ask the maintainer \
to move them over. See .claude/commands/release.md."

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

case "$tool" in
    Edit|Write|NotebookEdit|MultiEdit)
        path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
        case "$path" in
            */docs/CHANGELOG.md|docs/CHANGELOG.md) deny "$REASON" ;;
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
            deny "$REASON"
        fi
        # A copy, a move, or an in-place edit anywhere in the command.
        if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]|&;(])(tee|cp|mv|install|truncate|dd)([[:space:]]|$)'; then
            deny "$REASON"
        fi
        if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]|&;(])(sed|perl|ruby|python[0-9.]*|awk)[[:space:]][^|]*(-i|--in-place)'; then
            deny "$REASON"
        fi
        ;;
esac

echo '{}'
