#!/bin/bash
# Cuts a release:  ./release.sh 1.2.0 [--dry-run]
#   1. bumps CFBundleShortVersionString / CFBundleVersion in Info.plist
#   2. ./build.sh  → universal, cert-signed Build/CmdTabSwitcher.app
#   3. ./make-pkg.sh + ./make-dmg.sh + CmdTabSwitcher.zip
#   4. commit, tag vX.Y.Z, push, `gh release create` with all three artifacts
#
# Everything in the release is signed with the "CmdTabSwitcher Local Dev"
# certificate, so TCC grants survive from version to version and the in-app
# updater (which looks for CmdTabSwitcher.zip on the latest release) can swap
# the bundle without the user re-granting anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

VERSION="${1:-}"
DRY_RUN="${2:-}"
if [ -z "$VERSION" ]; then
  echo "usage: ./release.sh <version> [--dry-run]" >&2
  exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "!! version must look like 1.2.3" >&2
  exit 1
fi

APP_NAME="CmdTabSwitcher"
BUILD="$ROOT/Build"
PLIST="$ROOT/Info.plist"
TAG="v$VERSION"

CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
if [ "$CURRENT_VERSION" != "$VERSION" ]; then
  echo "==> Bumping Info.plist $CURRENT_VERSION ($CURRENT_BUILD) → $VERSION ($((CURRENT_BUILD + 1)))"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" "$PLIST"
else
  echo "==> Info.plist already at $VERSION ($CURRENT_BUILD) — re-running release, not bumping"
fi

"$ROOT/build.sh"
"$ROOT/make-pkg.sh"
"$ROOT/make-dmg.sh"

echo "==> Zipping app for the in-app updater"
ZIP="$BUILD/$APP_NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$BUILD/$APP_NAME.app" "$ZIP"

PKG="$BUILD/$APP_NAME-$VERSION.pkg"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
echo "==> Artifacts:"
ls -la "$DMG" "$PKG" "$ZIP"
shasum -a 256 "$DMG" "$PKG" "$ZIP"

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "==> --dry-run: not committing / tagging / publishing."
  exit 0
fi

# Notarize dmg+pkg when the machine is set up for it (Developer ID certs +
# stored notarytool credentials). notarize.sh exits 10 = "not configured",
# which is fine: the DMG's «Установить» path needs no notarization at all.
echo "==> Notarization"
set +e
"$ROOT/notarize.sh" "$DMG" "$PKG"
NOTARY_RC=$?
set -e
if [ "$NOTARY_RC" -ne 0 ] && [ "$NOTARY_RC" -ne 10 ]; then
  echo "!! notarization failed (rc=$NOTARY_RC) — release aborted, nothing published." >&2
  exit 1
fi

echo "==> Committing + tagging $TAG"
git add -A
git commit -m "Release $VERSION" || echo "(nothing to commit)"
git tag -f "$TAG"
git push origin HEAD
git push -f origin "$TAG"

echo "==> Publishing GitHub release $TAG"
NOTES="$(mktemp)"
if [ "$NOTARY_RC" -eq 0 ]; then
  GATEKEEPER_NOTE="Дистрибутив подписан Developer ID и нотаризован Apple — никаких предупреждений Gatekeeper, включая pkg и «перетащить в Программы»."
else
  GATEKEEPER_NOTE="Приложение не нотаризовано Apple (нужен аккаунт разработчика, см. README → Нотаризация) — поэтому ставь через «Установить» внутри dmg или командой из Способа 2: оба пути без единого диалога Gatekeeper."
fi
cat > "$NOTES" <<EOF
## Установка

**Способ 1 — DMG:** скачай \`$APP_NAME-$VERSION.dmg\`, открой, два клика по **«Установить»**.
Откроется Терминал, за пару секунд всё скопируется в «Программы» и запустится.

$GATEKEEPER_NOTE

**Способ 2 — одна команда в Terminal:**
\`\`\`
curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/CmdTabSwitcher/main/install.sh | bash
\`\`\`

После запуска приложение само покажет окно с двумя разрешениями (Accessibility, Screen Recording), откроет нужную вкладку настроек по кнопке и закроет окно, когда оба включены.

Работает на macOS 13+, Apple Silicon и Intel. Обновления ставятся из меню, права при этом сохраняются.

\`$APP_NAME-$VERSION.pkg\` — классический установщик macOS (без нотаризации macOS спросит «Open Anyway» один раз). \`$APP_NAME.zip\` — для автообновления, руками не качать.
EOF
gh release create "$TAG" "$DMG" "$PKG" "$ZIP" \
  --title "$APP_NAME $VERSION" \
  --notes-file "$NOTES" \
  --latest
rm -f "$NOTES"
echo "==> Released $TAG"
