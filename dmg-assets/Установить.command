#!/bin/bash
# Двойной клик по этому файлу ставит CmdTabSwitcher и сразу его запускает.
# Почему это вообще нужно: приложение не из App Store и не подписано платным
# сертификатом Apple (Developer ID, $99/год) — поэтому macOS Gatekeeper
# блокирует его при обычном запуске как "неизвестный разработчик". Этот
# скрипт снимает пометку "скачано из интернета" (com.apple.quarantine),
# из-за которой Gatekeeper вообще включается — дальше приложение работает
# как обычное, без предупреждений.
set -e
cd "$(dirname "$0")"

echo "Устанавливаю CmdTabSwitcher в /Applications…"
rm -rf "/Applications/CmdTabSwitcher.app"
cp -R "CmdTabSwitcher.app" "/Applications/CmdTabSwitcher.app"

echo "Снимаю карантин macOS (иначе Gatekeeper заблокирует запуск)…"
xattr -cr "/Applications/CmdTabSwitcher.app"

echo "Готово! Запускаю…"
open "/Applications/CmdTabSwitcher.app"

echo ""
echo "Приложение теперь живёт в строке меню (вверху экрана справа, значок с квадратиками)."
echo "При первом запуске оно само откроет System Settings и попросит два разрешения —"
echo "Accessibility и Screen Recording. Включи оба тумблера — без этого Cmd+Tab не заработает."
echo ""
echo "Это окно можно закрыть."
sleep 5
