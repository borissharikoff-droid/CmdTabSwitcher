#!/bin/bash
# Builds CmdTabSwitcher.app from source and installs it to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="CmdTabSwitcher"
APP_BUNDLE="$ROOT/Build/$APP_NAME.app"
BIN_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> Compiling..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

swiftc -O \
  -o "$BIN_PATH" \
  "$ROOT"/Sources/*.swift \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework ServiceManagement

cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# A stable local signing identity (not ad-hoc "-") so the code signature's
# designated requirement stays the same across rebuilds — otherwise macOS
# treats every rebuild as a brand-new app and silently revokes the
# Accessibility/Screen Recording grants you just gave it.
SIGN_ID="CmdTabSwitcher Local Dev"

echo "==> Code-signing ($SIGN_ID)..."
codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE"

echo "==> Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
codesign --force --deep --sign "$SIGN_ID" "/Applications/$APP_NAME.app"

echo "==> Done: /Applications/$APP_NAME.app"
