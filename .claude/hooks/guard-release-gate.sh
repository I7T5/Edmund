#!/usr/bin/env bash
# PreToolUse(Bash): a release never happens on autopilot.
#
# Pushing a `vX.Y.Z` tag is the trigger for .github/workflows/release.yml, which
# builds, signs and publishes the DMG and appends to appcast.xml — the one step
# in the pipeline that cannot be taken back, because Sparkle serves it and the
# shipped bundle self-identifies forever. On 2026-08-22 a release went out at
# the wrong version number with the wrong release-note wording because both were
# inferred from "merge and new release". Version and CHANGELOG text are the
# maintainer's editorial call, so this guard stops and shows them.
#
# Same file/stdin/stdout contract as the other guards here, so the OpenCode
# bridge (.opencode/plugin/edmund-guards.mjs) can run it too:
#   stdin  — hook JSON with .tool_input.command
#   stdout — `{}` to allow, or a hookSpecificOutput decision
#
# Objective failures deny. A release that passes every check still only gets
# "ask": passing checks means the numbers are consistent, not that they are the
# ones the maintainer wanted.
set -uo pipefail

cmd="$(jq -r '.tool_input.command // empty')"
[[ -n "$cmd" ]] || { echo '{}'; exit 0; }

decide() {
  jq -nc --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Is this command a release trigger?
#   - pushing a version tag (or any bulk tag push)
#   - gh release create
#   - scripts/release.sh, which builds, signs and creates the GitHub Release
is_push=false
grep -Eq '(^|&&|;|\||\()[[:space:]]*git[[:space:]]+push\b' <<<"$cmd" && is_push=true

if $is_push && grep -Eq -- '--tags|--follow-tags' <<<"$cmd"; then
  decide deny "Bulk tag push blocked: --tags/--follow-tags ships every local tag, so there is no single version to check.
Push the one release tag by name instead: git push origin vX.Y.Z"
fi

triggers=false
$is_push && grep -Eq '(^|[[:space:]:])v?[0-9]+\.[0-9]+\.[0-9]+([[:space:]]|$)' <<<"$cmd" && triggers=true
grep -Eq 'gh[[:space:]]+release[[:space:]]+create\b' <<<"$cmd" && triggers=true
grep -Eq 'scripts/release\.sh' <<<"$cmd" && triggers=true
$triggers || { echo '{}'; exit 0; }

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-.}")"
plist_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$root/Info.plist" 2>/dev/null || true)"
plist_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$root/Info.plist" 2>/dev/null || true)"

# Version named on the command line wins; otherwise the release takes whatever
# Info.plist says, which is what release.sh itself reads.
version="$(grep -Eo '\bv?[0-9]+\.[0-9]+\.[0-9]+\b' <<<"$cmd" | head -1 | sed 's/^v//')"
if [[ -z "$version" ]]; then
  [[ -n "$plist_version" ]] || decide deny "No version number: none on the command line and Info.plist CFBundleShortVersionString could not be read.
Say which version this release is."
  version="$plist_version"
fi

if [[ -n "$plist_version" && "$version" != "$plist_version" ]]; then
  decide deny "Version mismatch: this command releases $version but Info.plist CFBundleShortVersionString is $plist_version.
Sparkle ships the bundle's own number, so the two must agree. Bump Info.plist (and CFBundleVersion, currently $plist_build) or retag."
fi

# The CHANGELOG section is both the GitHub release body (release.sh awk-extracts
# it) and the Sparkle dialog HTML (scripts/changelog-to-html.py). No section,
# no release notes anywhere.
notes="$(awk -v v="$version" 'BEGIN{p=0} $0 ~ "^## \\[" v "\\]" {p=1;next} p && /^## \[/{exit} p{print}' "$root/docs/CHANGELOG.md" 2>/dev/null)"
if [[ -z "$(tr -d '[:space:]' <<<"$notes")" ]]; then
  decide deny "No CHANGELOG entry for $version: docs/CHANGELOG.md has no '## [$version]' section, or the section is empty.
Write the release notes first — that section becomes the GitHub release body and the Sparkle update dialog."
fi

decide ask "Release $version (build $plist_build) — irreversible once the tag is pushed. Confirm the version number and this wording:

$notes"
