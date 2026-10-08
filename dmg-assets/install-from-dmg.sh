#!/bin/bash
# Runs inside Terminal when the user double-clicks «Установить» on the .dmg
# (see Установить.terminal.template). Copies the app that ships next to this
# script into /Applications, drops the quarantine flag the copy would
# otherwise inherit from the downloaded image, and launches it. No Gatekeeper
# involvement at any point: the app is never *opened* while quarantined.
set -u

SRC="$(cd "$(dirname "$0")" && pwd)/CmdTabSwitcher.app"
APP="/Applications/CmdTabSwitcher.app"

echo
echo "  CmdTab Switcher — установка"
echo "  ==========================="
if [ ! -d "$SRC" ]; then
  echo "  !! Не нашёл CmdTabSwitcher.app рядом с установщиком ($SRC)."
  exit 1
fi

echo "  → Закрываю старую версию (если запущена)…"
pkill -x CmdTabSwitcher 2>/dev/null || true
sleep 1

echo "  → Копирую в /Applications…"
# Owned by the user → the in-app updater can replace it later without a
# password. If /Applications or an old root-owned copy isn't writable, ask
# for the admin password through the standard macOS dialog instead of
# leaving a half-installed app behind.
if ! { rm -rf "$APP" && /usr/bin/ditto "$SRC" "$APP"; } 2>/dev/null; then
  echo "    нужен пароль администратора — появится окно…"
  /usr/bin/osascript -e "do shell script \"rm -rf '$APP'; /usr/bin/ditto '$SRC' '$APP'; chown -R $(id -u):$(id -g) '$APP'\" with administrator privileges" >/dev/null || {
    echo "  !! Не удалось установить. Перетащи приложение в «Программы» вручную или выполни:"
    echo "     curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/CmdTabSwitcher/main/install.sh | bash"
    exit 1
  }
fi
xattr -cr "$APP" 2>/dev/null || true

echo "  → Запускаю…"
open -a "$APP"
echo
echo "  ✅ Готово. Дальше — окно с двумя разрешениями: включи оба тумблера."
echo "     Держи Cmd и жми Tab."
echo
sleep 3
exit 0
