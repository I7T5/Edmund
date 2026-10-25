#!/bin/bash
# Publishes the approved screenshots where the README and edmund.md show them.
#
# Usage: scripts/screenshots-publish.sh
#
# Every scripts/screenshots/<name>.shot with an `# alt:` header is published,
# in name order: its composed <name>-<mode>.png (the first of its modes) from
# $SHOTS_OUT (default misc/screenshots/<version>/, as scripts/screenshots.sh
# writes it) is copied to
#   docs/assets/screenshots/<name>.png         the README's images
#   site/public/assets/screenshots/<name>.png  edmund.md's images
# The paths stay the same from one set to the next, so publishing a new set
# changes images, not links. The set they replace is moved first to
# misc/archive/screenshots-<its version>/ (untracked).
#
# It also writes the image lists:
#   site/src/data/screenshots.json   the site's gallery, read by pages/index.astro
#   README.md                        the lines between <!-- screenshots --> and
#                                    <!-- /screenshots -->
# and docs/assets/screenshots/VERSION, the version the set shows.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
OUT="${SHOTS_OUT:-misc/screenshots/$VERSION}"
DOCS=docs/assets/screenshots
SITE=site/public/assets/screenshots

header() { sed -n "s/^# $2: *//p" "$1" | head -1; }

# Gather the set before touching anything, so a missing shot changes nothing.
names=(); files=(); alts=()
for shot in scripts/screenshots/*.shot; do
    alt="$(header "$shot" alt)"
    [ -n "$alt" ] || continue
    name="$(basename "$shot" .shot)"
    modes="$(header "$shot" modes)"; mode="${modes%% *}"
    png="$OUT/$name-${mode:-light}.png"
    [ -f "$png" ] || { echo "missing $png — take it with scripts/screenshots.sh $name"; exit 1; }
    names+=("$name"); files+=("$png"); alts+=("$alt")
done
[ ${#names[@]} -gt 0 ] || { echo "no shot has an # alt: header"; exit 1; }

# Archive the set being replaced.
if [ -d "$DOCS" ] && ls "$DOCS"/*.png >/dev/null 2>&1; then
    old="$(cat "$DOCS/VERSION" 2>/dev/null || echo unknown)"
    archive="misc/archive/screenshots-$old"
    mkdir -p "$archive"
    cp "$DOCS"/*.png "$archive/"
    git rm -q --cached "$DOCS"/*.png "$SITE"/*.png 2>/dev/null || true
    rm -f "$DOCS"/*.png "$SITE"/*.png
    echo "archived the $old set in $archive"
fi

mkdir -p "$DOCS" "$SITE" site/src/data
json="["; readme=""
for i in "${!names[@]}"; do
    cp "${files[$i]}" "$DOCS/${names[$i]}.png"
    cp "${files[$i]}" "$SITE/${names[$i]}.png"
    alt="${alts[$i]//\"/\\\"}"
    [ "$i" -gt 0 ] && json+=","
    json+=$'\n'"  { \"file\": \"${names[$i]}.png\", \"alt\": \"$alt\" }"
    readme+="![${alts[$i]}]($DOCS/${names[$i]}.png)"$'\n\n'
done
printf '%s\n]\n' "$json" > site/src/data/screenshots.json
echo "$VERSION" > "$DOCS/VERSION"

# The README's list, between its markers.
if grep -q '^<!-- screenshots -->$' README.md && grep -q '^<!-- /screenshots -->$' README.md; then
    block="$(mktemp)"; printf '%s' "$readme" > "$block"
    awk -v f="$block" '
        /^<!-- \/screenshots -->$/ { skip = 0 }
        !skip { print }
        /^<!-- screenshots -->$/ { print ""; while ((getline l < f) > 0) print l; skip = 1 }
    ' README.md > README.md.new && mv README.md.new README.md
    echo "README: ${#names[@]} images"
else
    echo "README has no <!-- screenshots --> / <!-- /screenshots --> markers; add them around its image list."
fi
echo "published ${#names[@]} shots ($VERSION)"
