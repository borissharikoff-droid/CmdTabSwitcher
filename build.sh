#!/bin/bash
# Builds Build/CmdTabSwitcher.app from source: a universal (Apple Silicon +
# Intel) binary that runs on macOS 13 Ventura and newer, signed with the
# project's stable local certificate.
#
#   ./build.sh            build + sign only
#   ./build.sh --install  …and also copy the result to /Applications and launch it
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="CmdTabSwitcher"
BUILD="$ROOT/Build"
APP_BUNDLE="$BUILD/$APP_NAME.app"
BIN_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
MIN_MACOS="13.0"

# Signing strategy:
#  • If a real Apple "Developer ID Application" certificate is in the keychain
#    (see README → Нотаризация), use it: hardened runtime + secure timestamp
#    are what notarization requires, and a notarized build is what makes
#    Gatekeeper stop warning on other people's Macs entirely.
#  • Otherwise fall back to the project's stable local certificate. Not
#    notarizable, but a stable designated requirement, so Accessibility /
#    Screen Recording grants survive every update.
IDENTITIES="$(security find-identity -v -p codesigning)"
# sed instead of grep: no match must yield an empty string, not a failed
# pipeline (set -o pipefail would kill the script on grep's exit code).
DEV_ID_APP="$(printf '%s\n' "$IDENTITIES" | sed -n 's/.*\("Developer ID Application[^"]*"\).*/\1/p' | head -n 1 | tr -d '"')"
if [ -n "$DEV_ID_APP" ]; then
  SIGN_ID="$DEV_ID_APP"
  SIGN_FLAGS=(--timestamp --options runtime)
  echo "==> Developer ID Application certificate found: $SIGN_ID"
else
  SIGN_ID="CmdTabSwitcher Local Dev"
  SIGN_FLAGS=(--timestamp=none)
  if ! printf '%s\n' "$IDENTITIES" | grep -q "\"$SIGN_ID\""; then
    echo "!! Signing identity \"$SIGN_ID\" not found in the keychain." >&2
    echo "   Create it (README.md → Сертификат) or restore it from the backup .p12 — do NOT" >&2
    echo "   fall back to ad-hoc signing, that is exactly what broke permissions in 1.0.x." >&2
    exit 1
  fi
fi

FRAMEWORKS=(-framework AppKit -framework ApplicationServices -framework CoreGraphics -framework ServiceManagement)

echo "==> Compiling (arm64 + x86_64, macOS $MIN_MACOS+)..."
rm -rf "$APP_BUNDLE" "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

for ARCH in arm64 x86_64; do
  swiftc -O \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -o "$BUILD/$APP_NAME-$ARCH" \
    "$ROOT"/Sources/*.swift \
    "${FRAMEWORKS[@]}"
done
lipo -create -output "$BIN_PATH" "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
rm -f "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"

cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Code-signing ($SIGN_ID)..."
codesign --force --deep --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" "$APP_BUNDLE"

echo "==> Verifying..."
lipo -info "$BIN_PATH"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
codesign -d -r- "$APP_BUNDLE" 2>&1 | grep designated

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications..."
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  open -a "/Applications/$APP_NAME.app"
  echo "==> Installed + launched: /Applications/$APP_NAME.app"
else
  echo "==> Done: $APP_BUNDLE"
fi
