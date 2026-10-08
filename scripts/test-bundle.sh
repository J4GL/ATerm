#!/bin/bash
# Tests for APP-BUNDLE-001 and APP-BUNDLE-002 (SPEC/app/bundle.md).
set -uo pipefail
cd "$(dirname "$0")/.."

APP=build/ATerm.app
PLIST="$APP/Contents/Info.plist"
failures=0
NAME=""

fail() {
    echo "✘ $NAME: $1"
    failures=$((failures + 1))
}

expect_key() {
    local key=$1 expected=$2 actual
    actual=$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null)
    [ "$actual" = "$expected" ] || fail "$key is '$actual', expected '$expected'"
}

report() {
    if [ "$failures" -eq "$1" ]; then echo "✔ $NAME"; fi
}

NAME="APP-BUNDLE-001 make app produces a signed launchable ATerm.app"
rm -rf build
if ! make app >/dev/null; then
    fail "make app failed"
    exit 1
fi

[ -f "$PLIST" ] || fail "missing $PLIST"
expect_key CFBundleIdentifier gl.j4.ATerm
expect_key CFBundleExecutable ATerm
expect_key CFBundleIconFile AppIcon
expect_key CFBundleShortVersionString 1.0.0
expect_key NSHighResolutionCapable true
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || fail "missing AppIcon.icns"
codesign --verify "$APP" 2>/dev/null || fail "codesign --verify failed"
version=$("$APP/Contents/MacOS/ATerm" --version 2>/dev/null)
[ "$version" = "ATerm 1.0.0" ] || fail "--version printed '$version'"
report 0

NAME="APP-BUNDLE-002 the app icon is the logo in a macOS icon tile"
before=$failures
WORK="$(mktemp -d)"
if iconutil -c iconset "$APP/Contents/Resources/AppIcon.icns" -o "$WORK/AppIcon.iconset" 2>/dev/null; then
    output=$(swift scripts/compare-icon.swift "$WORK/AppIcon.iconset" Resources/Logo.png 2>&1) \
        || while IFS= read -r line; do fail "$line"; done <<< "$output"
else
    fail "iconutil could not extract the iconset"
fi
rm -rf "$WORK"
report "$before"

[ "$failures" -eq 0 ] || exit 1
