#!/bin/bash
# One-line installer — no Gatekeeper dialogs at all, because files fetched by
# curl never get the quarantine flag:
#
#   curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/CmdTabSwitcher/main/install.sh | bash
#
# Downloads the latest release's CmdTabSwitcher.zip, puts the app in
# /Applications (replacing any older copy) and launches it. The app then asks
# for its two permissions itself.
set -euo pipefail

REPO="borissharikoff-droid/CmdTabSwitcher"
APP="/Applications/CmdTabSwitcher.app"
TMP="$(mktemp -d /tmp/cmdtab.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Looking up the latest release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*CmdTabSwitcher\.zip"' \
  | head -n 1 | sed 's/.*"\(https[^"]*\)"/\1/')
if [ -z "$URL" ]; then
  echo "!! Couldn't find CmdTabSwitcher.zip in the latest release." >&2
  exit 1
fi

echo "==> Downloading $URL"
curl -fL --progress-bar -o "$TMP/CmdTabSwitcher.zip" "$URL"
unzip -q -o "$TMP/CmdTabSwitcher.zip" -d "$TMP"
if [ ! -d "$TMP/CmdTabSwitcher.app" ]; then
  echo "!! Archive doesn't contain CmdTabSwitcher.app" >&2
  exit 1
fi

echo "==> Installing to $APP"
pkill -x CmdTabSwitcher 2>/dev/null || true
sleep 1
if [ -d "$APP" ] && [ ! -w "$APP" ]; then
  # Older copy owned by root (installed with sudo?) — needs a password once.
  sudo rm -rf "$APP"
else
  rm -rf "$APP"
fi
ditto "$TMP/CmdTabSwitcher.app" "$APP"
xattr -cr "$APP" 2>/dev/null || true

echo "==> Launching"
open -a "$APP"
echo "==> Done. Grant the two permissions in the window that pops up, then hold Cmd and press Tab."
