#!/bin/bash
# Build Edmund.app — a standalone macOS application bundle.
# Usage: ./scripts/build-app.sh [--variant sparkle|adhoc|mas]
#   sparkle (default): App Sandbox on (Resources/Edmund-Sparkle.entitlements),
#                      signed with the bundle id. What GitHub releases ship.
#   adhoc:             no entitlements, today's dev build. The sandbox blocks
#                      posting CGEvents, which the ReproScript live-repro driver
#                      needs, so local debugging stays on this variant.
#   mas:               Mac App Store: no Sparkle linked or embedded, no SU*
#                      Info.plist keys, Resources/Edmund.entitlements. Still
#                      ad-hoc signed here — App Store Connect signing
#                      (3rd Party Mac Developer certs + provisioning profile)
#                      is a separate, certificate-holding step.
# Output: build/Edmund.app (ready to drag into /Applications)

set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="sparkle"
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$VARIANT" in sparkle|adhoc|mas) ;; *) echo "Unknown variant: $VARIANT" >&2; exit 2 ;; esac

APP_NAME="Edmund"
BUNDLE="build/${APP_NAME}.app"
# The executable target is "edmd" (see Package.swift); the binary keeps that name
# inside the bundle even though the app presents as "Edmund".
EXECUTABLE="edmd"

echo "Building release binary (${VARIANT})..."
if [ "$VARIANT" = "mas" ]; then
    # EDMUND_MAS drops the Sparkle product from the edmd target (Package.swift).
    EDMUND_MAS=1 swift build -c release 2>&1 | tail -3
else
    swift build -c release 2>&1 | tail -3
fi

# SwiftMath ships 12 math fonts (~7 MB per bundle copy) but Edmund only ever
# renders with its default, Latin Modern: MathRenderer builds MTMathImage without
# setting a font, and MTMathImage.font defaults to MTFontManager.defaultFont.
# Fonts load lazily by name, so the unused ones can go. Licenses stay.
# If Edmund ever lets the user pick a math font, keep that font here.
prune_math_fonts() {
    local fonts="$1/SwiftMath_SwiftMath.bundle/mathFonts.bundle"
    [ -d "$fonts" ] || return 0
    find "$fonts" -maxdepth 1 \( -name '*.otf' -o -name '*.plist' -o -name '*.py' \) \
        ! -name 'latinmodern-math.*' -delete
}

echo "Creating ${APP_NAME}.app bundle..."
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp ".build/release/${EXECUTABLE}" "${BUNDLE}/Contents/MacOS/${EXECUTABLE}"
cp Info.plist "${BUNDLE}/Contents/"
if [ "$VARIANT" = "mas" ]; then
    # No updater on the App Store: Sparkle's keys must not ship there.
    for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUEnableInstallerLauncherService; do
        plutil -remove "$key" "${BUNDLE}/Contents/Info.plist"
    done
fi
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
# First-sandboxed-launch migration of Application Support/Edmund into the
# container (see the plist). Copied for every variant; inert unsandboxed.
cp Resources/container-migration.plist "${BUNDLE}/Contents/Resources/"

# Help ▸ Acknowledgments opens this page, the way Safari does its own:
# contributors, then every third-party license in LICENSES/.
{
    cat <<'HTML'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Edmund Acknowledgments</title>
<style>
:root { color-scheme: light dark; }
body { font: 13px -apple-system, sans-serif; max-width: 46em; margin: 2em auto; padding: 0 1em; }
pre { white-space: pre-wrap; font-size: 11px; }
</style></head><body>
<h1>Acknowledgments</h1>
<h2>Contributors</h2>
<p>Edmund is made by <a href="https://github.com/I7T5/Edmund/graphs/contributors">its contributors on GitHub</a>. Thank you.</p>
HTML
    for license in LICENSES/*.txt; do
        echo "<h2>$(basename "$license" .txt)</h2>"
        echo "<pre>"
        sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$license"
        echo "</pre>"
    done
    echo "</body></html>"
} > "${BUNDLE}/Contents/Resources/Acknowledgments.html"

# Compile the asset catalog so the app's AccentColor (our brown) is available.
# macOS uses it only when the user's system accent is "Multicolor"; a specific
# system accent still wins, which is the behavior we want.
# `actool` ships with full Xcode, not the Command Line Tools, so fall back to
# Xcode.app's copy when xcode-select points at the CLT.
echo "Compiling asset catalog..."
ACTOOL="$(xcrun --find actool 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/usr/bin/actool)"
"$ACTOOL" Resources/Assets.xcassets \
    --compile "${BUNDLE}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$(mktemp)" \
    >/dev/null

# Generate the App Intents metadata bundle (Metadata.appintents) that Shortcuts
# and Spotlight read to discover the intents in Intents.swift.
#
# KNOWN LIMITATION: appintentsmetadataprocessor needs per-file .swiftconstvalues
# supplementary outputs from the Swift compiler (it fails otherwise with
# "No swift const values found … BinaryScanningError error 6"). Xcode's build
# system requests those outputs via SWIFT_ENABLE_EMIT_CONST_VALUES; SwiftPM has
# no equivalent — passing -const-gather-protocols-file alone does not populate
# the output-file-map with const-values entries, so nothing is emitted. Until
# SwiftPM supports it (or the app is built from an Xcode project), the metadata
# bundle can't be produced here. The intents still compile and are correct; they
# simply won't appear in Shortcuts from a SwiftPM-built app. The Services-menu
# entries (Info.plist NSServices) provide the same "Open in Edmund" / "New
# Document with Selection" actions with no metadata dependency.
#
# The step below is left in, best-effort: it succeeds automatically the day the
# toolchain can emit the const values, and is a no-op warning until then.
echo "Generating App Intents metadata..."
AIMP="$(xcrun --find appintentsmetadataprocessor 2>/dev/null \
    || echo /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor)"
CONST_LIST="$(find .build/release -name '*.swiftconstvalues' 2>/dev/null | head -1 || true)"
if [ -x "$AIMP" ] && [ -n "$CONST_LIST" ]; then
    TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$AIMP")")")"
    CONST_FILELIST="$(mktemp)"
    find .build/release -name '*.swiftconstvalues' > "$CONST_FILELIST"
    "$AIMP" \
        --output "${BUNDLE}/Contents/Resources" \
        --module-name edmd \
        --target-triple "$(uname -m)-apple-macos14.0" \
        --toolchain-dir "$TOOLCHAIN_DIR" \
        --sdk-root "$(xcrun --show-sdk-path)" \
        --binary-file "${BUNDLE}/Contents/MacOS/${EXECUTABLE}" \
        --bundle-identifier com.i7t5.edmund \
        --source-files Sources/edmd/App/Intents.swift \
        --swift-const-vals-list "$CONST_FILELIST" \
        --deployment-target 14.0 \
        --xcode-version "$(xcodebuild -version 2>/dev/null | tail -1 | awk '{print $NF}')" \
        >/dev/null 2>&1 \
        && echo "  → Contents/Resources/Metadata.appintents" \
        || echo "  ! metadata export failed; intents work but Shortcuts discovery unavailable" >&2
else
    echo "  ! no .swiftconstvalues from SwiftPM build; Shortcuts discovery unavailable" >&2
    echo "    (intents still compile; use the Services menu, or build via an Xcode project)" >&2
fi

# Embed Sparkle.framework so the installed bundle is self-contained.
# SwiftPM links Sparkle but doesn't copy the framework (which carries the XPC
# helpers and Autoupdate.app) into the bundle; without this the updater crashes
# on the first check because it can't locate its helper processes.
if [ "$VARIANT" != "mas" ]; then
echo "Embedding Sparkle.framework..."
mkdir -p "${BUNDLE}/Contents/Frameworks"
SPARKLE_FW="$(find .build -type d -name 'Sparkle.framework' | grep -v '\.dSYM' | head -1)"
if [ -z "$SPARKLE_FW" ]; then
    echo "Error: Sparkle.framework not found in .build. Run 'swift build -c release' first." >&2
    exit 1
fi
cp -R "$SPARKLE_FW" "${BUNDLE}/Contents/Frameworks/"

# Fix the rpath so the binary resolves @rpath/Sparkle.framework at the bundle-
# relative path above rather than the build-artifacts path that won't exist once
# the app is installed.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${BUNDLE}/Contents/MacOS/${EXECUTABLE}" 2>/dev/null || true
fi

# Assemble the Quick Look preview extension as an .appex in Contents/PlugIns.
# It's an executable target (SwiftPM has no app-extension product); its entry
# point is Foundation's NSExtensionMain via the linker flag in Package.swift.
# Unlike the app's own SwiftMath bundle (copied to the .app root *after* the
# seal), the appex's resource bundles go inside Contents/Resources *before* it
# is signed, so they're sealed legally: an appex's Bundle.module resolves via
# Bundle.main.resourceURL, which for an .appex is Contents/Resources.
echo "Assembling Quick Look extension..."
QL_NAME="EdmundQuickLook"
APPEX="${BUNDLE}/Contents/PlugIns/${QL_NAME}.appex"
mkdir -p "${APPEX}/Contents/MacOS" "${APPEX}/Contents/Resources"
cp ".build/release/${QL_NAME}" "${APPEX}/Contents/MacOS/${QL_NAME}"
cp Resources/QuickLookInfo.plist "${APPEX}/Contents/Info.plist"
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "${APPEX}/Contents/Resources/"
done
prune_math_fonts "${APPEX}/Contents/Resources"

# Code sign the bundle as a properly *sealed* bundle — not just the binary.
#
# Why this matters: at install time Sparkle re-validates the downloaded update's
# Apple code signature (SUUpdateValidator). Even with a valid EdDSA signature, if
# the bundle reports as code-signed but fails SecStaticCodeCheckValidity, Sparkle
# rejects the update as "improperly signed and could not be validated." Signing
# only the standalone binary (as we used to) produces a bundle with no
# _CodeSignature seal, which fails that check — so every Sparkle update was
# rejected.
#
# Sign inside-out: Sparkle.framework first (its nested XPC helpers must be signed
# before macOS will launch them), then the whole .app. We seal the app while its
# root contains only Contents/, because codesign refuses to seal a bundle that
# has extra items at the .app root ("unsealed contents present in the bundle
# root"). The SwiftMath resource bundle has to live at the .app root at runtime
# (see below), so we copy it in *after* sealing. That leaves one unsealed item at
# the root, which `codesign --verify` (CLI) and --strict flag — but Sparkle's
# actual check is non-strict (SecStaticCodeCheckValidityWithErrors with
# kSecCSCheckAllArchitectures), which tolerates it. Verified end-to-end.
echo "Code signing..."
# Sign inside-out, then seal the app WITHOUT --deep. --deep on the outer .app
# would re-sign every nested item with default flags — stripping the appex's
# sandbox entitlements and resetting its identifier to the app's. Instead we
# sign each nested item explicitly (Sparkle deep so its own XPC helpers are
# covered; the appex with its entitlements) and let the non-deep app sign just
# seal the container over the already-signed contents.
[ "$VARIANT" != "mas" ] && codesign --force --deep --sign - "${BUNDLE}/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements Resources/QuickLook.entitlements \
    --identifier "com.i7t5.edmund.quicklook" "$APPEX"
# The sandboxed variants sign with no --identifier override: the signing id
# names the container (~/Library/Containers/<id>) and keys the automatic
# preferences migration, so it must equal the Info.plist bundle id. The ad-hoc
# variant keeps its historical "com.i7t5.edmd" id.
case "$VARIANT" in
    sparkle) codesign --force --sign - --entitlements Resources/Edmund-Sparkle.entitlements "$BUNDLE" ;;
    mas)     codesign --force --sign - --entitlements Resources/Edmund.entitlements "$BUNDLE" ;;
    adhoc)   codesign --force --sign - --identifier "com.i7t5.edmd" "$BUNDLE" ;;
esac

# SwiftPM dependencies that ship resources (SwiftMath's math fonts) emit a
# per-target bundle next to the binary. SwiftMath's generated Bundle.module
# accessor looks for it at Bundle.main.bundleURL — i.e. the .app root — and only
# otherwise at a hardcoded absolute .build path that doesn't exist once the app
# is installed. So it must sit at the .app root; copy it in *after* signing (it
# can't be sealed there — see above) so the bundle's own seal stays valid.
# Without this the app crashes the moment it renders any LaTeX.
echo "Copying SwiftPM resource bundles..."
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "${BUNDLE}/"
done
prune_math_fonts "$BUNDLE"

echo ""
echo "Done: ${BUNDLE} (variant: ${VARIANT})"
echo "To install: cp -R ${BUNDLE} /Applications/"
