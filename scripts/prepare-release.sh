#!/bin/bash
# Prepare Edmund for a release: set the marketing version, bump the build
# number, and check that the changelog is ready.
#
# Usage: ./scripts/prepare-release.sh <version> [--check]
#
#   <version>   Marketing version, e.g. 0.3.1 (a leading "v" is accepted).
#   --check     Report only; write nothing.
#
# Writes Info.plist:
#   CFBundleShortVersionString := <version>     (what users see)
#   CFBundleVersion            := previous + 1  (Sparkle's ordering key, so it
#                                                has to rise on every release)
#
# Never writes docs/CHANGELOG.md — that file is the maintainer's. This script
# only checks that the version's section exists, and points at misc/changelog-tmp
# (untracked scratch) when it doesn't.
#
# Publishing itself stays in scripts/release.sh; run that afterwards.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
CHECK_ONLY=""
[ "${2:-}" = "--check" ] && CHECK_ONLY=1

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/prepare-release.sh <version> [--check]" >&2
    exit 2
fi

VERSION="${VERSION#v}"
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: '$VERSION' is not a semantic version (x.y.z)." >&2
    exit 2
fi

PLIST=Info.plist
CURRENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
NEXT_BUILD=$((BUILD + 1))

echo "Version:  ${CURRENT} -> ${VERSION}"
echo "Build:    ${BUILD} -> ${NEXT_BUILD}"

# ── Sanity: never go backwards, never re-cut a shipped version ───────────────
if [ "$VERSION" = "$CURRENT" ]; then
    echo "Error: Info.plist is already at ${VERSION}. Nothing to bump." >&2
    exit 1
fi
# sort -V puts the lower version first; if that's the new one, it's a downgrade.
LOWEST="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | head -1)"
if [ "$LOWEST" = "$VERSION" ]; then
    echo "Error: ${VERSION} is older than the current ${CURRENT}." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
    echo "Error: tag v${VERSION} already exists — that release is out." >&2
    exit 1
fi

# ── Changelog: read-only check ───────────────────────────────────────────────
# release.sh takes both the GitHub release body and the Sparkle update note
# from this section, so a missing one ships a release with no notes at all.
CHANGELOG=docs/CHANGELOG.md
SECTION="$(awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" {p=1; next}
    p && /^## \[/ {exit}
    p {print}
' "$CHANGELOG")"

CHANGELOG_OK=1
if [ -z "$(echo "$SECTION" | tr -d '[:space:]')" ]; then
    CHANGELOG_OK=""
    echo
    echo "Changelog: NO section for ${VERSION} in ${CHANGELOG}."
    if [ -s misc/changelog-tmp ]; then
        echo "           Draft notes are waiting in misc/changelog-tmp:"
        sed 's/^/           | /' misc/changelog-tmp
    else
        echo "           Collect the notes in misc/changelog-tmp first (untracked)."
    fi
    echo "           ${CHANGELOG} is yours: write it, or have /release write your"
    echo "           approved wording (it asks first). This script never writes it."
else
    echo
    echo "Changelog: found the ${VERSION} section ($(echo "$SECTION" | grep -c '^- ') entries)."
fi

if [ -n "$CHECK_ONLY" ]; then
    echo
    echo "--check: Info.plist untouched."
    [ -n "$CHANGELOG_OK" ] || exit 1
    exit 0
fi

if [ -z "$CHANGELOG_OK" ]; then
    echo
    echo "Refusing to bump: write the ${VERSION} section first." >&2
    exit 1
fi

# ── Write ────────────────────────────────────────────────────────────────────
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" "$PLIST"

echo
echo "Info.plist updated. Next:"
echo "  1. swift test"
echo "  2. git commit -am 'chore(release): ${VERSION}'"
echo "  3. ./scripts/release.sh   (builds, signs, publishes v${VERSION})"
