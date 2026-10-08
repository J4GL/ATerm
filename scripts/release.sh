#!/bin/bash
# Builds the app, signs it with a Developer ID, notarizes and staples it: dist/ATerm-<version>.zip and
# dist/RELEASE_NOTES-<version>.md (SPEC/app/bundle.md, APP-BUNDLE-003).
#
# Needs a "Developer ID Application" identity in the keychain (SIGN_IDENTITY overrides it) and notarytool
# credentials stored once, as the keychain profile NOTARY_PROFILE (default PLAY_NOTARY, the team's profile):
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-PLAY_NOTARY}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)
APP=build/ATerm.app
ZIP="dist/ATerm-$VERSION.zip"
NOTES="dist/RELEASE_NOTES-$VERSION.md"

# The release notes first: a missing changelog entry stops the release before anything is sent to Apple.
mkdir -p dist
awk -v heading="## [$VERSION]" 'index($0, heading) == 1 { found = 1; next } found && /^## \[/ { exit } found' \
    CHANGELOG.md > "$NOTES"
[ -n "$(tr -d '[:space:]' < "$NOTES")" ] || { echo "CHANGELOG.md has no section ## [$VERSION]." >&2; exit 1; }

ARCHS="arm64 x86_64" scripts/bundle.sh
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

# Notarize the signed app, then staple the ticket so Gatekeeper accepts it offline.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Released $ZIP and $NOTES"
