#!/bin/sh
# Packs "Apple Mail MCP.app" into a drag-to-Applications disk image.
#   Scripts/make-dmg.sh [app] [dmg]
#   defaults: ~/Library/Caches/AppleMailMCP/dist/Apple Mail MCP.app -> …/dist/AppleMailMCP.dmg
# Run Scripts/build-app.sh first. The image is signed when SIGN_IDENTITY is set; notarization is
# a separate step (see .github/workflows/release.yml).
set -eu

CACHE="$HOME/Library/Caches/AppleMailMCP"
APP="${1:-$CACHE/dist/Apple Mail MCP.app}"
DMG="${2:-$CACHE/dist/AppleMailMCP.dmg}"
STAGE="$CACHE/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Apple Mail MCP.app"
ln -s /Applications "$STAGE/Applications"

# hdiutil now and then fails with "Resource busy" on CI runners, so retry a few times.
for attempt in 1 2 3 4 5; do
    hdiutil create -volname "Apple Mail MCP" -srcfolder "$STAGE" -format UDZO -ov "$DMG" && break
    [ "$attempt" = 5 ] && exit 1
    sleep 5
done
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "Built $DMG"
