#!/usr/bin/env bash
# PreToolUse(Bash): never commit a red tree.
#
# Claude Code enforces this from the other end — a Stop hook runs `swift test`
# at the end of every turn that touches code. OpenCode has no end-of-turn hook
# whose output reaches the model, so the suite has to run at the moment it
# actually decides something: the commit itself.
#
# Written as a guard script rather than plugin code so both agents can use it,
# and so the rule lives in one place. Only the OpenCode bridge wires it today;
# Claude Code keeps its Stop hook (see .claude/settings.json).
set -uo pipefail

cmd="$(jq -r '.tool_input.command // empty')"
[[ -n "$cmd" ]] || { echo '{}'; exit 0; }

grep -Eq '(^|&&|;|\|)[[:space:]]*git[[:space:]]+commit\b' <<<"$cmd" || { echo '{}'; exit 0; }

# Docs-only commit: nothing the suite can tell us. Skip the two-minute wait.
git diff --cached --name-only | grep -q '\.swift$' || { echo '{}'; exit 0; }

if ! out="$(swift test 2>&1)"; then
  jq -nc --arg tail "$(tail -20 <<<"$out")" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("swift test failed — commit blocked (project rule: never commit a red tree).\n" + $tail)
    }
  }'
  exit 0
fi

echo '{}'
