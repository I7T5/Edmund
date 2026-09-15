#!/usr/bin/env bash
# PreToolUse guard: the maintainer's own prose is not agent-editable.
#
# Blocks Edit/Write/NotebookEdit on the repo-root README.md and misc/backlog.md.
# Those two are the maintainer's voice — user-facing copy and a hand-sorted
# priority list — and a "small wording fix" there is invisible without a diff.
# The rule is written up in .claude/skills/edmund-docs-and-writing/SKILL.md §7;
# this hook is the part that doesn't rely on an agent having read it.
#
# Deliberately narrow:
#   * The root README only. `docs/architecture/README.md` and any other nested
#     README are the engineering record — freely editable. "Root" is decided by
#     `Package.swift` sitting next to the file, not by the session's cwd, so it
#     holds in every worktree.
#   * `misc/backlog.md` only. Creating any *other* file under `misc/` is
#     explicitly fine and needs no permission.
#   * Read is untouched — agents still need to quote these files.
set -euo pipefail

path="$(jq -r '.tool_input.file_path // empty')"
[[ -n "$path" ]] || { echo '{}'; exit 0; }

case "$path" in
  */misc/backlog.md) what="misc/backlog.md — the maintainer's hand-sorted priority list" ;;
  */README.md)
    # Root README only: the one with Package.swift beside it.
    if [[ -f "$(dirname "$path")/Package.swift" ]]; then
      what="README.md — the project's user-facing front page"
    else
      echo '{}'; exit 0
    fi
    ;;
  *) echo '{}'; exit 0 ;;
esac

jq -nc --arg what "$what" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ($what + " is the maintainer'"'"'s prose, not the engineering record. Do not edit it unasked — report the change you would make and let them decide. See .claude/skills/edmund-docs-and-writing/SKILL.md §7. (ARCHITECTURE.md, docs/architecture/**, docs/investigations/** and new files under misc/ are all fair game.)")
  }
}'
