#!/bin/bash
# Packs the installer into Build/CmdTabSwitcher-<version>.dmg:
#   • Установить CmdTabSwitcher.pkg   — double-click, done
#   • Если не открывается.txt         — the one Gatekeeper step, spelled out
# Run ./build.sh and ./make-pkg.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="CmdTabSwitcher"
BUILD="$ROOT/Build"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Info.plist")
PKG="$BUILD/$APP_NAME-$VERSION.pkg"
STAGING="$BUILD/dmg-staging"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

if [ ! -f "$PKG" ]; then
  echo "!! $PKG not found — run ./build.sh && ./make-pkg.sh first." >&2
  exit 1
fi

echo "==> Staging DMG contents"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp "$PKG" "$STAGING/Установить CmdTabSwitcher.pkg"
cp "$ROOT/dmg-assets/Если не открывается.txt" "$STAGING/"

echo "==> Creating $DMG"
hdiutil create \
  -volname "CmdTab Switcher $VERSION" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGING"
echo "==> Done: $DMG"
