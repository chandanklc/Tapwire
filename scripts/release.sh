#!/bin/bash
# Builds a Release copy of Tapwire and packages it as a DMG.
#
#   scripts/release.sh                 ad-hoc signed DMG (runs on this Mac; other Macs must allow it in Privacy & Security)
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   TEAM_ID=TEAMID NOTARY_PROFILE=tapwire-notary scripts/release.sh
#                                      signed, notarized and stapled DMG anyone can open
#
# One-time setup for notarization (stores an app-specific password in your Keychain):
#   xcrun notarytool store-credentials tapwire-notary --apple-id you@example.com --team-id TEAMID
#
# Output: build/dist/Tapwire-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build/release"
DIST="$ROOT/build/dist"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v xcodegen >/dev/null || fail "xcodegen is not installed (brew install xcodegen)"

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || fail "could not read MARKETING_VERSION from project.yml"

if [ -n "$SIGN_IDENTITY" ]; then
    security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
        || fail "signing identity not found in your Keychain: $SIGN_IDENTITY"
    [ -n "$TEAM_ID" ] || fail "set TEAM_ID together with SIGN_IDENTITY"
    MODE="Developer ID"
else
    MODE="ad-hoc"
fi
echo "Tapwire $VERSION, $MODE signing"

step "Generating the Xcode project"
xcodegen generate --quiet

step "Building (Release)"
SIGN_ARGS=(CODE_SIGN_STYLE=Manual)
if [ -n "$SIGN_IDENTITY" ]; then
    SIGN_ARGS+=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" OTHER_CODE_SIGN_FLAGS="--timestamp")
else
    SIGN_ARGS+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild -project Tapwire.xcodeproj -scheme Tapwire -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$BUILD" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=YES "${SIGN_ARGS[@]}" \
    clean build | grep -E "error:|warning: .*Sources/|BUILD (SUCCEEDED|FAILED)" || true
APP="$BUILD/Build/Products/Release/Tapwire.app"
[ -d "$APP" ] || fail "build failed, see the output above"

step "Checking the signature"
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/Tapwire"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Signature)=" || true

step "Creating the DMG"
mkdir -p "$DIST"
DMG="$DIST/Tapwire-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Tapwire.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Tapwire $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    step "Notarizing (this usually takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    step "Gatekeeper check"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "note: NOTARY_PROFILE not set, so the DMG is signed but not notarized."
else
    echo "note: ad-hoc signed. Other Macs block it the first time: open it, then click Open Anyway in"
    echo "      System Settings > Privacy & Security (or run: xattr -dr com.apple.quarantine /Applications/Tapwire.app)."
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
step "Done: $DMG"
