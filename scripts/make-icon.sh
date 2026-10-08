#!/bin/bash
# Draws the app icon from Resources/Logo.png and writes Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift Resources/Logo.png "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote Resources/AppIcon.icns"
