#!/bin/sh
# Builds "Apple Mail MCP.app" (arm64, release): the menu bar app plus the apple-mail-mcp server
# binary next to it in Contents/MacOS, so MCP clients and the app share one signed location.
#   Scripts/build-app.sh            -> ~/Library/Caches/AppleMailMCP/dist/Apple Mail MCP.app
#   Scripts/build-app.sh --install  -> also copies it to ~/Applications and relaunches it
# Build output lives outside the repo: files in Documents carry Finder metadata, which codesign
# refuses ("resource fork, Finder information, or similar detritus").
# Signing: SIGN_IDENTITY; else a "Developer ID Application" identity from the keychain; else the
# local "Apple Mail MCP Local Signing" certificate (Scripts/create-signing-identity.sh); else ad-hoc.
# A stable signature keeps the Full Disk Access and Automation grants across rebuilds; ad-hoc
# signatures change every build and macOS asks again. Developer ID also gets a secure timestamp,
# which notarization requires.
# VERSION and BUILD_NUMBER, when set, stamp the bundle's version (the release workflow sets them).
set -eu
cd "$(dirname "$0")/.."

CACHE="$HOME/Library/Caches/AppleMailMCP"
BUILD="$CACHE/build"
APP="$CACHE/dist/Apple Mail MCP.app"

swift build -c release --arch arm64 --scratch-path "$BUILD" --product MailMCPBar
swift build -c release --arch arm64 --scratch-path "$BUILD" --product apple-mail-mcp
BIN="$(swift build -c release --arch arm64 --scratch-path "$BUILD" --show-bin-path)"

[ -f Resources/AppIcon.icns ] || swift Scripts/make-icon.swift Resources

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$BIN/MailMCPBar" "$APP/Contents/MacOS/Apple Mail MCP"
ditto --norsrc --noextattr "$BIN/apple-mail-mcp" "$APP/Contents/MacOS/apple-mail-mcp"
ditto --norsrc --noextattr Resources/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noextattr Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
VERSION="${VERSION:-$(sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p' Sources/MailMCPKit/MailMCPServer.swift | head -n 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
xattr -cr "$APP"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-certificate -c "Apple Mail MCP Local Signing" -Z 2>/dev/null | awk '/SHA-1/ {print $3}')"
fi
case "${SIGN_IDENTITY:-}" in "Developer ID"*) TIMESTAMP=--timestamp ;; *) TIMESTAMP= ;; esac
# The server binary is nested code: sign it first, then the app around it.
for target in "$APP/Contents/MacOS/apple-mail-mcp" "$APP"; do
    codesign --force --options runtime $TIMESTAMP --entitlements Resources/entitlements.plist \
        --sign "${SIGN_IDENTITY:--}" "$target"
done
codesign --verify --strict --deep "$APP"
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Apple Mail MCP"), signed by ${SIGN_IDENTITY:--})"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications/Apple Mail MCP.app"
    pkill -x "Apple Mail MCP" 2>/dev/null && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
