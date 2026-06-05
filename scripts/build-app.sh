#!/bin/bash
# Build md.app — a standalone macOS application bundle.
# Usage: ./scripts/build-app.sh
# Output: build/md.app (ready to drag into /Applications)

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="md"
BUNDLE="build/${APP_NAME}.app"
EXECUTABLE="md"

echo "Building release binary..."
swift build -c release 2>&1 | tail -3

echo "Creating ${APP_NAME}.app bundle..."
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp ".build/release/${EXECUTABLE}" "${BUNDLE}/Contents/MacOS/${EXECUTABLE}"
cp Info.plist "${BUNDLE}/Contents/"

# Ad-hoc codesign so macOS doesn't quarantine-block it
codesign --force --sign - "${BUNDLE}"

echo ""
echo "Done: ${BUNDLE}"
echo "To install: cp -R ${BUNDLE} /Applications/"
