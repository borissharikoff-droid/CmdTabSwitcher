#!/bin/bash
# Builds a standard "drag app into Applications" .dmg installer from
# whatever's currently in /Applications/CmdTabSwitcher.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Info.plist")
DMG_NAME="CmdTabSwitcher-$VERSION.dmg"
STAGE="$ROOT/Build/dmg-stage"

SOURCE_APP="$ROOT/Build/CmdTabSwitcher-dist.app"
if [ ! -d "$SOURCE_APP" ]; then
  echo "!! Build/CmdTabSwitcher-dist.app not found — run release.sh first (it produces"
  echo "   the ad-hoc-signed distribution copy this DMG is built from)."
  exit 1
fi

echo "==> Staging"
rm -rf "$STAGE" "$ROOT/Build/$DMG_NAME"
mkdir -p "$STAGE"
cp -R "$SOURCE_APP" "$STAGE/CmdTabSwitcher.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/dmg-assets/Установить.command" "$STAGE/Установить.command"
chmod +x "$STAGE/Установить.command"
cp "$ROOT/dmg-assets/Если не открывается.txt" "$STAGE/Если не открывается.txt"

echo "==> Creating $DMG_NAME"
hdiutil create -volname "CmdTabSwitcher $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$ROOT/Build/$DMG_NAME"

rm -rf "$STAGE"
echo "==> Done: $ROOT/Build/$DMG_NAME"
