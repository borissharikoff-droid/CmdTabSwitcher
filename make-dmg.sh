#!/bin/bash
# Builds a standard "drag app into Applications" .dmg installer from
# whatever's currently in /Applications/CmdTabSwitcher.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Info.plist")
DMG_NAME="CmdTabSwitcher-$VERSION.dmg"
STAGE="$ROOT/Build/dmg-stage"

echo "==> Staging"
rm -rf "$STAGE" "$ROOT/Build/$DMG_NAME"
mkdir -p "$STAGE"
cp -R "/Applications/CmdTabSwitcher.app" "$STAGE/CmdTabSwitcher.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG_NAME"
hdiutil create -volname "CmdTabSwitcher $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$ROOT/Build/$DMG_NAME"

rm -rf "$STAGE"
echo "==> Done: $ROOT/Build/$DMG_NAME"
