#!/bin/bash
# Builds the release executable and assembles build/ATerm.app (SPEC/app/bundle.md).
set -euo pipefail
cd "$(dirname "$0")/.."

# ARCHS (e.g. "arm64 x86_64" for a universal release) defaults to this Mac's architecture.
ARCH_FLAGS=()
for arch in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release --product ATerm ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
APP=build/ATerm.app

# Redraw the icon when the logo changed.
[ Resources/AppIcon.icns -nt Resources/Logo.png ] || scripts/make-icon.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ATerm" "$APP/Contents/MacOS/ATerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad hoc signature: required to run on Apple silicon, no developer identity needed.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
