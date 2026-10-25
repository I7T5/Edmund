#!/bin/bash
# Mac App Store package: builds the mas variant, re-signs it for distribution,
# wraps it in a signed installer package, and optionally validates or uploads it.
#
# Usage: ./scripts/mas-package.sh [--validate | --upload]
#
# Needs, all outside the repo:
#   - "Apple Distribution" and "3rd Party Mac Developer Installer" identities in
#     the login keychain
#   - Mac App Store provisioning profiles in $MAS_PROFILES (default
#     ~/.appstoreconnect/profiles), named <bundle id>.provisionprofile, for the
#     app and both Quick Look extensions
#   - for --validate / --upload: ASC_KEY_ID and ASC_ISSUER_ID; altool reads
#     AuthKey_<ASC_KEY_ID>.p8 from ~/.appstoreconnect/private_keys
# Output: build/Edmund-<version>.pkg
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-}"
PROFILES="${MAS_PROFILES:-$HOME/.appstoreconnect/profiles}"
SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Distribution: .*\)"$/\1/p' | head -1)"
PKG_ID="$(security find-identity -v | sed -n 's/.*"\(3rd Party Mac Developer Installer: .*\)"$/\1/p' | head -1)"
if [ -z "$SIGN_ID" ] || [ -z "$PKG_ID" ]; then
    echo "Error: need Apple Distribution and 3rd Party Mac Developer Installer identities." >&2
    exit 1
fi
TEAM="$(echo "$SIGN_ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"

./scripts/build-app.sh --variant mas
APP=build/Edmund.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
WORK="$(mktemp -d)"

# sign <bundle> <bundle id> <entitlements>: embeds the bundle's profile and signs
# it with its entitlements plus the two the profile grants. Inside-out — each
# appex before the app — and never --deep, which would re-sign the appexes with
# the app's entitlements.
sign() {
    local bundle="$1" id="$2" entitlements="$3"
    local profile="$PROFILES/$id.provisionprofile" merged="$WORK/$id.entitlements"
    if [ ! -f "$profile" ]; then
        echo "Error: no provisioning profile at $profile" >&2; exit 1
    fi
    cp "$profile" "$bundle/Contents/embedded.provisionprofile"
    cp "$entitlements" "$merged"
    # PlistBuddy, not plutil: plutil reads the dots in these keys as a key path.
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$id" \
        -c "Add :com.apple.developer.team-identifier string $TEAM" "$merged"
    codesign --force --sign "$SIGN_ID" --entitlements "$merged" "$bundle"
}
echo "Signing for the App Store (${SIGN_ID})..."
sign "$APP/Contents/PlugIns/EdmundQuickLook.appex" com.i7t5.edmund.quicklook Resources/QuickLook.entitlements
sign "$APP/Contents/PlugIns/EdmundThumbnail.appex" com.i7t5.edmund.thumbnail Resources/Thumbnail.entitlements
sign "$APP" com.i7t5.edmund Resources/Edmund.entitlements
codesign --verify --strict --deep "$APP"

PKG="build/Edmund-${VERSION}.pkg"
productbuild --component "$APP" /Applications --sign "$PKG_ID" "$PKG"
echo "Built $PKG"

case "$ACTION" in
    --validate|--upload)
        : "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
        xcrun altool "${ACTION}-app" -f "$PKG" -t macos \
            --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" ;;
    "") ;;
    *) echo "Unknown argument: $ACTION" >&2; exit 2 ;;
esac
