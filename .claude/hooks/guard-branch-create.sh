#!/usr/bin/env bash
# PreToolUse(Bash): creating a branch means reaching for a worktree instead.
#
# Was an inline jq one-liner in .claude/settings.json. It lives in a file now so
# that .opencode/plugin/edmund-guards.mjs can execute it directly — OpenCode has
# no settings.json, and a rule that exists only as JSON embedded in one agent's
# config cannot be shared with another. Every guard in this directory is a file
# with the same contract, and the OpenCode bridge runs all of them.
#
# Contract (Claude Code's PreToolUse shape, which the bridge also speaks):
#   stdin  — hook JSON with .tool_input.command / .tool_input.file_path
#   stdout — `{}` to allow, or a hookSpecificOutput deny decision
set -uo pipefail

# Whole command, not just its first line: the old `read -r cmd` saw only line 1,
# so a heredoc or multi-line && chain slipped straight past this guard.
cmd="$(jq -r '.tool_input.command // empty')"
[[ -n "$cmd" ]] || { echo '{}'; exit 0; }

is_branch_create() {
  grep -Eq '(^|&&|;|\|)[[:space:]]*git[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c)\b' <<<"$cmd" ||
    # Bare `git branch <name>` creates; `-a`, `-d`, `--list` do not.
    grep -Eq '(^|&&|;|\|)[[:space:]]*git[[:space:]]+branch[[:space:]]+[^-[:space:]][^[:space:]]*([[:space:]]|$)' <<<"$cmd"
}

if is_branch_create; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Edmund prefers git worktrees over branch-switching for concurrent local work: git worktree add .worktrees/<branch> <branch> (branch keeps its normal type/slug name). See CLAUDE.md Git practices / docs/ARCHITECTURE.md §12."
    }
  }'
  exit 0
fi

echo '{}'
