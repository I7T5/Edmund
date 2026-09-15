#!/usr/bin/env bash
# PostToolUse(Edit|Write): keep the OpenCode setup in step with .claude/.
#
# Only two of the four .claude/ surfaces actually need anything:
#
#   skills/      nothing to do. OpenCode discovers .claude/skills/<name>/SKILL.md
#                natively (kill switch: OPENCODE_DISABLE_CLAUDE_CODE_SKILLS), and
#                the frontmatter is the same name+description pair. Verified live:
#                all 16 show up in `GET /skill` on `opencode serve`.
#   CLAUDE.md    likewise — OpenCode walks the project tree for AGENTS.md /
#                CLAUDE.md / CONTEXT.md. Nothing to sync.
#   commands/    DOES need work, and a plain cp is wrong: OpenCode only parses
#                the frontmatter when it recognises every key. Leave Claude's
#                `allowed-tools:` / `argument-hint:` in and parsing fails
#                silently — the description is dropped and the whole `---` block
#                leaks into the prompt. So regenerate with a description-only
#                whitelist rather than copying.
#   hooks/       nothing to do either, as of the guard-bridge change.
#                .opencode/plugin/edmund-guards.mjs no longer re-implements the
#                guards, it executes guard-*.sh directly, so an edit to one is
#                live on both sides immediately. A new guard-*.sh is picked up
#                by OpenCode automatically; Claude Code needs one line in
#                .claude/settings.json, having no auto-discovery.
#
# Writes only into .opencode/, which is gitignored — no tracked churn.

set -uo pipefail

path="$(jq -r '.tool_input.file_path // empty')"
[[ -n "$path" ]] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -n "$root" && -d "$root/.claude" ]] || exit 0

case "$path" in
  "$root"/.claude/commands/*.md) ;;
  *) exit 0 ;;   # guards need no sync — see the header
esac

src="$root/.claude/commands"
dst="$root/.opencode/command"
mkdir -p "$dst"

# Full regenerate: picks up adds, edits and deletes in one pass. Two small files.
find "$dst" -maxdepth 1 -name '*.md' -delete

for f in "$src"/*.md; do
  [[ -e "$f" ]] || continue
  # Keep only `description` inside the frontmatter; pass the body through as-is.
  # ponytail: single-line description only — the repo's commands all use one.
  # A folded `description: >` would need a real YAML parser.
  awk '
    NR == 1 && $0 == "---" { infm = 1; print; next }
    infm && $0 == "---"    { infm = 0; print; next }
    infm                   { if ($0 ~ /^description:/) print; next }
                           { print }
  ' "$f" > "$dst/$(basename "$f")"
done

echo "synced $(ls -1 "$dst"/*.md 2>/dev/null | wc -l | tr -d ' ') command(s) to .opencode/command/" >&2
exit 2
