#!/bin/bash
# Submits release artifacts to Apple's notary service and staples the
# tickets. Fully automatic once the machine is set up (README → Нотаризация):
#   • "Developer ID Application" / "Developer ID Installer" certificates in
#     the keychain (build.sh / make-pkg.sh pick them up by themselves), and
#   • notarytool credentials stored once:
#       xcrun notarytool store-credentials CmdTabSwitcher \
#         --apple-id YOU@example.com --team-id TEAMID --password APP-SPECIFIC-PW
#
# Without those, prints why and exits 10 — release.sh then skips notarization
# and publishes the Gatekeeper-free «Установить» DMG instead of failing.
#
# Usage: ./notarize.sh <artifact> [artifact ...]   (.dmg / .pkg)
set -euo pipefail

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "notarize: нет сертификата Developer ID Application — пропускаю (README → Нотаризация)"
  exit 10
fi

PROFILE=""
for candidate in "${NOTARY_PROFILE:-}" CmdTabSwitcher notarytool notary; do
  [ -n "$candidate" ] || continue
  if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
    PROFILE="$candidate"
    break
  fi
done
if [ -z "$PROFILE" ]; then
  echo "notarize: нет сохранённых учётных данных notarytool — пропускаю (README → Нотаризация)"
  exit 10
fi
echo "notarize: профиль keychain «$PROFILE»"

for f in "$@"; do
  echo "notarize: отправляю $f"
  xcrun notarytool submit "$f" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$f"
  xcrun stapler validate "$f"
done
echo "notarize: готово"
