#!/bin/bash
# Builds, verifies and packages Kiwi for other people to install.
#
#   ./scripts/release.sh
#       Uses the same signing identity as `make run` (Kiwi Local, or ad hoc).
#       Fine for your own Macs. On someone else's Mac, Gatekeeper will refuse
#       the app until they allow it by hand.
#
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="kiwi" ./scripts/release.sh
#       Signs with a Developer ID and notarizes, so the app opens normally
#       anywhere. NOTARY_PROFILE is a keychain profile created once with
#       `xcrun notarytool store-credentials`.
#
# Output goes to dist/: a zip, a dmg and SHA256SUMS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/Kiwi.app"
DIST="dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
NAME="Kiwi-$VERSION"

if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    echo "warning: there are uncommitted changes; this build will not match any commit."
fi

echo "==> Building and verifying Kiwi $VERSION"
make clean >/dev/null
if [ -n "${SIGN_ID:-}" ]; then
    make verify SIGN_ID="$SIGN_ID"
else
    make verify
fi

rm -rf "$DIST"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

package() {
    rm -f "$DIST/$NAME.zip" "$DIST/$NAME.dmg"
    rm -rf "$STAGE/dmg"
    mkdir -p "$STAGE/dmg"
    # ditto keeps the code signature and extended attributes intact.
    /usr/bin/ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"
    /usr/bin/ditto "$APP" "$STAGE/dmg/Kiwi.app"
    ln -s /Applications "$STAGE/dmg/Applications"
    /usr/bin/hdiutil create -quiet -volname "Kiwi $VERSION" -srcfolder "$STAGE/dmg" \
        -ov -format UDZO "$DIST/$NAME.dmg"
}

echo "==> Packaging"
package

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DIST/$NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    # Package again so both files carry the stapled app, then notarize the disk image too.
    package
    xcrun notarytool submit "$DIST/$NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST/$NAME.dmg"
    NOTARIZED="yes"
else
    NOTARIZED="no"
fi

(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS)

echo
echo "Kiwi $VERSION packaged in $DIST/:"
ls -lh "$DIST" | tail -n +2 | awk '{print "  " $NF "  (" $5 ")"}'
echo
cat "$DIST/SHA256SUMS" | sed 's/^/  /'
echo
codesign -dv "$APP" 2>&1 | grep -E '^(Authority|Signature|TeamIdentifier)' | sed 's/^/  /' || true
echo "  Notarized: $NOTARIZED"
if [ "$NOTARIZED" = "no" ]; then
    echo
    echo "This build is not notarized. On another Mac, Gatekeeper blocks it on first"
    echo "launch; the owner has to allow it under System Settings > Privacy & Security."
    echo "A Developer ID and NOTARY_PROFILE (see the top of this script) remove that step."
fi
