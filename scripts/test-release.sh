#!/bin/bash
# Test for APP-BUNDLE-003 (SPEC/app/bundle.md). Signs and notarizes for real: it needs a Developer ID Application
# identity and the notarytool profile (NOTARY_PROFILE, default PLAY_NOTARY).
set -uo pipefail
cd "$(dirname "$0")/.."

NAME="APP-BUNDLE-003 make release produces a notarized stapled ATerm zip and its release notes"
VERSION=1.0.0
ZIP="dist/ATerm-$VERSION.zip"
NOTES="dist/RELEASE_NOTES-$VERSION.md"
failures=0

fail() {
    echo "✘ $NAME: $1"
    failures=$((failures + 1))
}

rm -rf dist
if ! make release; then
    echo "✘ $NAME: make release failed"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -f "$ZIP" ] || fail "missing $ZIP"
ditto -x -k "$ZIP" "$WORK" || fail "cannot unzip $ZIP"
entries=$(ls -A "$WORK")
[ "$entries" = "ATerm.app" ] || fail "the zip holds '$entries', expected ATerm.app"
APP="$WORK/ATerm.app"

codesign --verify --strict --deep "$APP" 2>/dev/null || fail "codesign --verify --strict --deep failed"
details=$(codesign -dvv "$APP" 2>&1)
grep -q "^Authority=Developer ID Application:" <<< "$details" || fail "not signed with a Developer ID Application identity"
grep -q "flags=.*runtime" <<< "$details" || fail "no hardened runtime"
grep -q "^Timestamp=" <<< "$details" || fail "no secure timestamp"
archs=$(lipo -archs "$APP/Contents/MacOS/ATerm" 2>/dev/null)
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || fail "executable architectures: '$archs'"
xcrun stapler validate "$APP" >/dev/null 2>&1 || fail "no stapled notarization ticket"
assessment=$(spctl --assess --type execute -vv "$APP" 2>&1)
grep -q "accepted" <<< "$assessment" && grep -q "source=Notarized Developer ID" <<< "$assessment" \
    || fail "Gatekeeper: $assessment"
version=$("$APP/Contents/MacOS/ATerm" --version 2>/dev/null)
[ "$version" = "ATerm $VERSION" ] || fail "--version printed '$version'"

expected=$(awk -v heading="## [$VERSION]" 'index($0, heading) == 1 { found = 1; next } found && /^## \[/ { exit } found' CHANGELOG.md)
[ -s "$NOTES" ] || fail "missing or empty $NOTES"
[ "$(cat "$NOTES" 2>/dev/null)" = "$expected" ] || fail "$NOTES is not the $VERSION section of CHANGELOG.md"
[ -n "$(tr -d '[:space:]' <<< "$expected")" ] || fail "the $VERSION section of CHANGELOG.md is empty"

[ "$failures" -eq 0 ] || exit 1
echo "✔ $NAME"
