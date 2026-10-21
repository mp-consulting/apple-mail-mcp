#!/bin/sh
# Builds "Apple Mail MCP.app" (release): the menu bar app, with the apple-mail-mcp server in its own bundle at
# Contents/Helpers/Apple Mail MCP Server.app (the path MCP clients start), so both share one signed location.
# Also dist/apple-mail-mcp: the same server alone, for the Claude extension (Scripts/make-mcpb.sh).
#   Scripts/build-app.sh            -> ~/Library/Caches/AppleMailMCP/dist/Apple Mail MCP.app
#   Scripts/build-app.sh --install  -> also copies it to ~/Applications and relaunches it
# Build output lives outside the repo: files in Documents carry Finder metadata, which codesign
# refuses ("resource fork, Finder information, or similar detritus").
# Signing: SIGN_IDENTITY; else a "Developer ID Application" identity from the keychain; else the
# local "Apple Mail MCP Local Signing" certificate (Scripts/create-signing-identity.sh); else ad-hoc.
# A stable signature keeps the Full Disk Access and Automation grants across rebuilds; ad-hoc
# signatures change every build and macOS asks again. Developer ID also gets a secure timestamp,
# which notarization requires.
# VERSION and BUILD_NUMBER, when set, stamp the bundle's version (the release workflow sets them); the git commit is
# stamped too (AppleMailMCPCommit).
# ARCHS picks the architectures (default: universal, "arm64 x86_64"; set ARCHS=arm64 for faster local builds).
set -eu
cd "$(dirname "$0")/.."

CACHE="$HOME/Library/Caches/AppleMailMCP"
BUILD="$CACHE/build"
APP="$CACHE/dist/Apple Mail MCP.app"

ARCH_FLAGS=""
for arch in ${ARCHS:-arm64 x86_64}; do ARCH_FLAGS="$ARCH_FLAGS --arch $arch"; done
swift build -c release $ARCH_FLAGS --scratch-path "$BUILD" --product MailMCPBar
swift build -c release $ARCH_FLAGS --scratch-path "$BUILD" --product apple-mail-mcp
BIN="$(swift build -c release $ARCH_FLAGS --scratch-path "$BUILD" --show-bin-path)"

[ -f Resources/AppIcon.icns ] || swift Scripts/make-icon.swift Resources

# SwiftPM's build system can record the deployment target as the SDK version (`sdk 14.0` in LC_BUILD_VERSION, seen
# with Xcode 27). macOS then treats the app as built for macOS 14 and gives it the pre-26 look: square-ish menu window,
# no Liquid Glass. Stamp the SDK the binaries were really built with (unsigned copies, before codesign).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
stamp_sdk() {
    vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$1.stamped" "$1"
    mv "$1.stamped" "$1"
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$BIN/MailMCPBar" "$APP/Contents/MacOS/Apple Mail MCP"
ditto --norsrc --noextattr Resources/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noextattr Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
VERSION="${VERSION:-$(sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p' Sources/MailMCPKit/MailMCPServer.swift | head -n 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
# The commit, so the server can say which build a client started (MailMCPVersion.build); "-dirty" with local changes.
COMMIT="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-dirty"
/usr/libexec/PlistBuddy -c "Set :AppleMailMCPCommit $COMMIT" "$APP/Contents/Info.plist"
# The server's bundle shares the app's identifier, version and usage descriptions (Contacts, Automation).
HELPER="$APP/Contents/Helpers/Apple Mail MCP Server.app"
mkdir -p "$HELPER/Contents/MacOS"
ditto --norsrc --noextattr "$BIN/apple-mail-mcp" "$HELPER/Contents/MacOS/apple-mail-mcp"
cp "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable apple-mail-mcp" -c "Set :CFBundleName Apple Mail MCP Server" \
    -c "Set :CFBundleDisplayName Apple Mail MCP Server" -c "Delete :CFBundleIconFile" "$HELPER/Contents/Info.plist"
STANDALONE="$(dirname "$APP")/apple-mail-mcp"
ditto --norsrc --noextattr "$BIN/apple-mail-mcp" "$STANDALONE"
for binary in "$APP/Contents/MacOS/Apple Mail MCP" "$HELPER/Contents/MacOS/apple-mail-mcp" "$STANDALONE"; do
    stamp_sdk "$binary"
done
xattr -cr "$APP"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-certificate -c "Apple Mail MCP Local Signing" -Z 2>/dev/null | awk '/SHA-1/ {print $3}')"
fi
case "${SIGN_IDENTITY:-}" in "Developer ID"*) TIMESTAMP=--timestamp ;; *) TIMESTAMP= ;; esac

# The team's Developer ID with its provisioning profile: the app and the server claim the Keychain access group
# (KeychainSecret). macOS honours a profile only for a bundle's main executable, hence the server's own bundle, each
# with the profile embedded. The standalone copy claims nothing, so it runs outside the app; it and builds with other
# signatures fall back to the login Keychain.
PROFILE=Resources/AppleMailMCP.provisionprofile
ENTITLEMENTS=Resources/entitlements.plist
case "${SIGN_IDENTITY:-}" in
"Developer ID"*"(4HWBUF2R8D)")
    [ -f "$PROFILE" ] || { echo "missing $PROFILE" >&2; exit 1; }
    ENTITLEMENTS="$CACHE/entitlements-keychain.plist"
    cp Resources/entitlements.plist "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.application-identifier string 4HWBUF2R8D.com.mpconsulting.AppleMailMCP" \
        -c "Add :com.apple.developer.team-identifier string 4HWBUF2R8D" \
        -c "Add :keychain-access-groups array" \
        -c "Add :keychain-access-groups:0 string 4HWBUF2R8D.com.mpconsulting.AppleMailMCP" "$ENTITLEMENTS"
    cp "$PROFILE" "$HELPER/Contents/embedded.provisionprofile"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ;;
esac

# Nested code first, then the app around it.
for target in "$HELPER" "$APP"; do
    codesign --force --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" --sign "${SIGN_IDENTITY:--}" "$target"
done
codesign --force --options runtime $TIMESTAMP --entitlements Resources/entitlements.plist \
    --sign "${SIGN_IDENTITY:--}" "$STANDALONE"
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
