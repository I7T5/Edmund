#!/bin/bash
# Build Edmund.app — a standalone macOS application bundle.
# Usage: ./scripts/build-app.sh
# Output: build/Edmund.app (ready to drag into /Applications)

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Edmund"
BUNDLE="build/${APP_NAME}.app"
# The executable target is "edmd" (see Package.swift); the binary keeps that name
# inside the bundle even though the app presents as "Edmund".
EXECUTABLE="edmd"

echo "Building release binary..."
swift build -c release 2>&1 | tail -3

echo "Creating ${APP_NAME}.app bundle..."
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp ".build/release/${EXECUTABLE}" "${BUNDLE}/Contents/MacOS/${EXECUTABLE}"
cp Info.plist "${BUNDLE}/Contents/"
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"

# SwiftPM dependencies that ship resources (SwiftMath's math fonts) emit a
# per-target bundle next to the binary. SwiftMath's generated Bundle.module
# accessor looks for it at Bundle.main.bundleURL — i.e. the .app root — and only
# otherwise at a hardcoded absolute .build path that doesn't exist once the app is
# installed. Copy the bundle into the .app root so it's self-contained; without
# this the app crashes the moment it renders any LaTeX.
echo "Copying SwiftPM resource bundles..."
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "${BUNDLE}/"
done

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

# Embed Sparkle.framework so the installed bundle is self-contained.
# SwiftPM links Sparkle but doesn't copy the framework (which carries the XPC
# helpers and Autoupdate.app) into the bundle; without this the updater crashes
# on the first check because it can't locate its helper processes.
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

# Sign Sparkle's framework (--deep handles its nested XPC services and helpers,
# which macOS requires to be signed before it will launch them).
#
# Sign the main binary by copying it out of the bundle first. The SwiftMath
# resource bundle lives at the .app root (outside Contents/) because
# Bundle.main.bundleURL is where its generated accessor looks — there is no
# way to move it. That non-standard placement makes codesign's strict bundle-
# seal mode reject the outer bundle with "unsealed contents present in the
# bundle root". Signing the binary as a temporary standalone file sidesteps
# that check; the resulting ad-hoc signature is identical to what bundle-mode
# signing would produce for the executable itself.
echo "Code signing..."
codesign --force --sign - --deep "${BUNDLE}/Contents/Frameworks/Sparkle.framework"
TMP_BIN="$(mktemp)"
cp "${BUNDLE}/Contents/MacOS/${EXECUTABLE}" "$TMP_BIN"
codesign --force --sign - --identifier "com.i7t5.edmd" "$TMP_BIN"
cp "$TMP_BIN" "${BUNDLE}/Contents/MacOS/${EXECUTABLE}"
rm "$TMP_BIN"

echo ""
echo "Done: ${BUNDLE}"
echo "To install: cp -R ${BUNDLE} /Applications/"
