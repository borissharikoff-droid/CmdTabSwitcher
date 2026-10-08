#!/bin/bash
# Wraps Build/CmdTabSwitcher.app into a standard macOS installer package:
# Build/CmdTabSwitcher-<version>.pkg. Run ./build.sh first.
#
# Why a .pkg and not "drag the app to Applications": files placed by
# Installer.app never get the com.apple.quarantine flag, so Gatekeeper never
# screens the app itself — no "damaged", no "unidentified developer", no
# translocation to a random read-only path (which is what made permissions
# refuse to stick). The only Gatekeeper encounter left is the .pkg file
# itself, once, with the well-known "Open Anyway" button.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="CmdTabSwitcher"
BUILD="$ROOT/Build"
APP_BUNDLE="$BUILD/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Info.plist")
PKG_ID="com.local.cmdtabswitcher.pkg"
PKG_ROOT="$BUILD/pkg-root"
COMPONENT_PLIST="$BUILD/pkg-component.plist"
COMPONENT_PKG="$BUILD/$APP_NAME-component.pkg"
DIST_XML="$BUILD/pkg-distribution.xml"
OUT_PKG="$BUILD/$APP_NAME-$VERSION.pkg"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "!! $APP_BUNDLE not found — run ./build.sh first." >&2
  exit 1
fi

echo "==> Staging payload"
rm -rf "$PKG_ROOT" "$COMPONENT_PLIST" "$COMPONENT_PKG" "$DIST_XML" "$OUT_PKG"
mkdir -p "$PKG_ROOT/Applications"
ditto "$APP_BUNDLE" "$PKG_ROOT/Applications/$APP_NAME.app"

# By default pkgbuild marks app bundles "relocatable": Installer would then
# happily update a stray copy in ~/Downloads instead of /Applications. Pin it.
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked false" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleOverwriteAction upgrade" "$COMPONENT_PLIST"

chmod +x "$ROOT/pkg/scripts/preinstall" "$ROOT/pkg/scripts/postinstall"

echo "==> Building component package"
pkgbuild \
  --root "$PKG_ROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --scripts "$ROOT/pkg/scripts" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT_PKG" >/dev/null

echo "==> Building installer $OUT_PKG"
sed "s/__VERSION__/$VERSION/g" "$ROOT/pkg/distribution.xml" > "$DIST_XML"
# A "Developer ID Installer" signature (plus notarization, see notarize.sh)
# is what lets the .pkg itself pass Gatekeeper silently. Without it the pkg
# still installs fine — via «Установить» on the DMG or with the one-time
# "Open Anyway" — it's just not the zero-dialog path.
# sed instead of grep: no match must yield an empty string, not a failed
# pipeline (set -o pipefail would kill the script on grep's exit code).
DEV_ID_PKG="$(security find-identity -v -p codesigning | sed -n 's/.*\("Developer ID Installer[^"]*"\).*/\1/p' | head -n 1 | tr -d '"')"
if [ -n "$DEV_ID_PKG" ]; then
  echo "==> Signing installer package with: $DEV_ID_PKG"
  productbuild \
    --distribution "$DIST_XML" \
    --resources "$ROOT/pkg/resources" \
    --package-path "$BUILD" \
    --sign "$DEV_ID_PKG" \
    "$OUT_PKG" >/dev/null
else
  productbuild \
    --distribution "$DIST_XML" \
    --resources "$ROOT/pkg/resources" \
    --package-path "$BUILD" \
    "$OUT_PKG" >/dev/null
fi

rm -rf "$PKG_ROOT" "$COMPONENT_PLIST" "$COMPONENT_PKG" "$DIST_XML"
echo "==> Done: $OUT_PKG"
