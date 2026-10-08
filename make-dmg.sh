#!/bin/bash
# Builds Build/CmdTabSwitcher-<version>.dmg. Run ./build.sh first.
#
# Volume layout:
#   Установить                   ← .terminal document; double-click installs + launches
#   Если не открывается.txt      ← plain-text fallback instructions
#   .payload/CmdTabSwitcher.app  ← hidden, so nobody drags/launches it while quarantined
#   .payload/install-<ver>.sh    ← what «Установить» runs (version-stamped path)
#
# Why not an app or a .pkg on the image: anything *executable* that was
# downloaded is quarantined and, without a $99/yr Apple Developer ID +
# notarization, Sequoia greets it with "Apple could not verify… / Move to
# Trash". A .terminal file is a *document* for Apple's own Terminal — it
# isn't signature-checked — and the script it runs copies the app with plain
# ditto and strips the quarantine flag, so the app is never opened while
# quarantined and Gatekeeper never gets a turn.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="CmdTabSwitcher"
BUILD="$ROOT/Build"
APP_BUNDLE="$BUILD/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Info.plist")
STAGING="$BUILD/dmg-staging"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
VOLNAME="CmdTabSwitcher"   # must match the /Volumes/CmdTabSwitcher* glob in the .terminal

if [ ! -d "$APP_BUNDLE" ]; then
  echo "!! $APP_BUNDLE not found — run ./build.sh first." >&2
  exit 1
fi

echo "==> Staging DMG contents"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING/.payload"
ditto "$APP_BUNDLE" "$STAGING/.payload/$APP_NAME.app"
cp "$ROOT/dmg-assets/install-from-dmg.sh" "$STAGING/.payload/install-$VERSION.sh"
chmod +x "$STAGING/.payload/install-$VERSION.sh"
sed "s/__VERSION__/$VERSION/g" "$ROOT/dmg-assets/Установить.terminal.template" > "$STAGING/Установить.terminal"
plutil -lint "$STAGING/Установить.terminal" >/dev/null
cp "$ROOT/dmg-assets/Если не открывается.txt" "$STAGING/"
# When the app is Developer ID-signed (→ notarizable), also show it next to
# the installer for the classic drag-to-Applications flow. With only the
# local cert a dragged-out copy would carry quarantine and hit Gatekeeper —
# so there it stays hidden in .payload and «Установить» is the only path.
if codesign -dvv "$APP_BUNDLE" 2>&1 | grep -q "Authority=Developer ID Application"; then
  ditto "$APP_BUNDLE" "$STAGING/$APP_NAME.app"
  ln -s /Applications "$STAGING/Applications"
fi
# Hide the ".terminal" extension in Finder so it reads as just «Установить».
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a E "$STAGING/Установить.terminal"
fi

echo "==> Creating $DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGING"
echo "==> Done: $DMG"
