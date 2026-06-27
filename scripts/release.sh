#!/bin/bash
# Publish a new Edmund release.
#
# Usage: ./scripts/release.sh
#
# Prerequisites:
#   1. Run `generate_keys` once and put the public key in Info.plist SUPublicEDKey.
#   2. The Sparkle private key must be in the login keychain (placed there by
#      `generate_keys`) OR exported as SPARKLE_ED_PRIVATE_KEY in the environment
#      (used in CI). The script auto-detects which path to take.
#   3. `gh` CLI must be installed and authenticated (for the GitHub Release step).
#   4. create-dmg installed via npm: `npm install --global create-dmg`
#      (this is sindresorhus/create-dmg, NOT the homebrew create-dmg/create-dmg
#      tool — they have incompatible CLIs).
#
# Output:
#   - build/Edmund-<version>.dmg  (signed archive)
#   - appcast.xml updated with the new <item> (commit + push it yourself)
#   - GitHub Release created with the DMG as an asset

set -euo pipefail
cd "$(dirname "$0")/.."

# ── Version from Info.plist ──────────────────────────────────────────────────
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
DMG="build/Edmund-${VERSION}.dmg"

echo "Releasing Edmund ${VERSION} (build ${BUILD})"

# ── Build ────────────────────────────────────────────────────────────────────
./scripts/build-app.sh

# ── Disk image ────────────────────────────────────────────────────────────────
# create-dmg exits 2 when it can't Developer-ID-sign / notarize the image (we
# ship ad-hoc only) but still produces the .dmg, so tolerate that status and
# verify the file exists instead. It names the output "Edmund <version>.dmg";
# normalize to the hyphenated name the appcast URL expects.
rm -f "$DMG" "build/Edmund ${VERSION}.dmg"
create-dmg build/Edmund.app build/ || true
DMG_SRC="$(ls build/Edmund*.dmg 2>/dev/null | grep -v "Edmund-${VERSION}.dmg" | head -1)"
if [ -z "$DMG_SRC" ]; then
    echo "Error: create-dmg produced no .dmg." >&2
    echo "Install it with: npm install --global create-dmg" >&2
    exit 1
fi
mv "$DMG_SRC" "$DMG"
echo "Archive: $DMG ($(du -sh "$DMG" | cut -f1))"

# ── Locate sign_update ────────────────────────────────────────────────────────
SIGN_UPDATE="$(find .build -name sign_update -type f | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
    echo "Error: sign_update not found. Run 'swift build' to fetch Sparkle tools." >&2
    exit 1
fi

# ── EdDSA signature ───────────────────────────────────────────────────────────
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    # CI path: private key passed via env (base64 string, no keychain)
    SIG_OUTPUT="$("$SIGN_UPDATE" -s "$SPARKLE_ED_PRIVATE_KEY" "$DMG")"
else
    # Local path: key lives in the login keychain (placed there by generate_keys)
    SIG_OUTPUT="$("$SIGN_UPDATE" "$DMG")"
fi

# sign_update prints:  sparkle:edSignature="<sig>" length="<n>"
ED_SIG="$(echo "$SIG_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"')"
LENGTH="$(echo "$SIG_OUTPUT" | grep -o 'length="[^"]*"' | head -1)"

echo "Signature: $ED_SIG"

# ── Build the GitHub Release asset URL ────────────────────────────────────────
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
ASSET_URL="https://github.com/${REPO}/releases/download/v${VERSION}/Edmund-${VERSION}.dmg"

# ── Prepend item to appcast.xml ───────────────────────────────────────────────
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
NEW_ITEM="        <item>
            <title>Edmund ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <enclosure url=\"${ASSET_URL}\"
                       sparkle:version=\"${BUILD}\"
                       sparkle:shortVersionString=\"${VERSION}\"
                       ${ED_SIG}
                       ${LENGTH}
                       type=\"application/x-apple-diskimage\"/>
        </item>"

# Insert the new item right after <channel>...<language>en</language>
python3 - "$NEW_ITEM" <<'PYEOF'
import sys, re
new_item = sys.argv[1]
with open("appcast.xml", "r") as f:
    content = f.read()
# Insert before closing </channel>
content = content.replace("    </channel>", new_item + "\n    </channel>")
with open("appcast.xml", "w") as f:
    f.write(content)
PYEOF

echo "appcast.xml updated."

# ── GitHub Release ────────────────────────────────────────────────────────────
echo "Creating GitHub Release v${VERSION}..."

# Extract this version's section from CHANGELOG.md as the release body.
# Falls back to a plain link if the section isn't found.
NOTES_FILE=$(mktemp)
awk "BEGIN{p=0} /^## \[${VERSION}\]/{p=1;next} p && /^## \[/{exit} p{print}" CHANGELOG.md > "$NOTES_FILE"
if [ ! -s "$NOTES_FILE" ]; then
    echo "See [CHANGELOG](https://github.com/${REPO}/blob/main/CHANGELOG.md) for details." > "$NOTES_FILE"
fi

gh release create "v${VERSION}" "$DMG" \
    --title "Edmund ${VERSION}" \
    --notes-file "$NOTES_FILE" \
    --latest
rm -f "$NOTES_FILE"

echo ""
echo "Done. Next steps:"
echo "  1. git add appcast.xml && git commit -m 'Release ${VERSION}' && git push"
echo "  2. Verify: open https://github.com/${REPO}/releases/tag/v${VERSION}"
