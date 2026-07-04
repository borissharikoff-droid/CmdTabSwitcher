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

echo "==> Building"
./build.sh

echo "==> Zipping (ditto preserves the bundle exactly, incl. code signature)"
rm -f "Build/CmdTabSwitcher.zip"
ditto -c -k --sequesterRsrc --keepParent "/Applications/CmdTabSwitcher.app" "Build/CmdTabSwitcher.zip"

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
