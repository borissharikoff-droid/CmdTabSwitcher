#!/bin/bash
# Bump the version, build+sign, zip, tag, push, and publish a GitHub Release
# with the zip attached. This is the file CmdTabSwitcher.swift's Updater.swift
# polls (GitHub Releases "latest"), so running this is the entire "ship an
# update to everyone who has the app installed" workflow.
#
# Usage: ./release.sh 1.0.1
set -euo pipefail

VERSION="${1:?Usage: ./release.sh <version, e.g. 1.0.1>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "==> Bumping version to $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" Info.plist

echo "==> Building (signed with the stable local dev cert — for this machine)"
./build.sh

# The public artifact is re-signed ad-hoc instead of with the local dev
# certificate. A self-signed cert that a stranger's Mac has never seen chains
# to nothing it trusts, and on current macOS that can get Gatekeeper to call
# the app "damaged" outright — a harder block than the classic, well-trodden
# "unidentified developer" path that a plain ad-hoc signature gets. Anyone
# who isn't this dev machine should get the friendlier path.
# Staged in its own directory under the CORRECT final name — "--keepParent"
# below preserves whatever the source folder is literally named inside the
# zip, so this app must already be called "CmdTabSwitcher.app" here, not
# some "-dist" suffixed build artifact name (that exact bug silently broke
# every auto-update from v1.0.2 through v1.0.7: Updater.swift looks for
# "CmdTabSwitcher.app" post-unzip and always found nothing).
DIST_STAGE="Build/dist-stage"
DIST_APP="$DIST_STAGE/CmdTabSwitcher.app"
echo "==> Preparing distribution copy (ad-hoc signature)"
rm -rf "$DIST_STAGE"
mkdir -p "$DIST_STAGE"
cp -R "Build/CmdTabSwitcher.app" "$DIST_APP"
codesign --force --deep --sign - "$DIST_APP"

echo "==> Zipping"
rm -f "Build/CmdTabSwitcher.zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST_APP" "Build/CmdTabSwitcher.zip"

echo "==> Committing + tagging"
git add -A
git commit -m "Release v$VERSION" || echo "(nothing to commit)"
git tag -f "v$VERSION"
git push origin main
git push origin "v$VERSION" --force

echo "==> Publishing GitHub Release"
gh release delete "v$VERSION" --yes 2>/dev/null || true
gh release create "v$VERSION" "Build/CmdTabSwitcher.zip" \
  --title "v$VERSION" \
  --notes "CmdTabSwitcher v$VERSION"

echo "==> Done. Installed apps will pick this up within 6h, or instantly via the menu bar → Проверить обновления."
echo "==> Note: friends' Accessibility/Screen Recording grants may need re-confirming after an"
echo "    auto-update, since the public build is ad-hoc signed (see release.sh comments)."
