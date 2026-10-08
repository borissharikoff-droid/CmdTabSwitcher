# CmdTab Switcher

Cmd+Tab, который переключает **окна**, а не приложения. Живые превью, порядок «последнее использованное — первым», Cmd+Shift+Tab назад, Esc — отмена, клик мышью по карточке.

macOS 13 Ventura и новее · Apple Silicon и Intel (universal) · живёт в строке меню.

## Установка

### Способ 1 — DMG
1. Скачай `CmdTabSwitcher-x.y.z.dmg` из [последнего релиза](https://github.com/borissharikoff-droid/CmdTabSwitcher/releases/latest).
2. Открой dmg → два клика по **«Установить CmdTabSwitcher.pkg»** → Продолжить → Установить → пароль.
3. Приложение запустится само и покажет окно с двумя разрешениями. Нажми «Открыть настройки…» и включи тумблер напротив CmdTabSwitcher — для **Accessibility** и для **Screen Recording**. Окно закроется само.
4. Держи Cmd, жми Tab.

Если macOS не даёт открыть pkg («Apple не может проверить…») — это Gatekeeper, один раз:
**System Settings → Privacy & Security → в самом низу «Open Anyway» / «Всё равно открыть»** → пароль. На macOS 13–14 достаточно правого клика по pkg → «Открыть».

### Способ 2 — одна команда в Terminal (вообще без Gatekeeper)
```bash
curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/CmdTabSwitcher/main/install.sh | bash
```
У файлов, скачанных `curl`, нет флага карантина, поэтому никаких диалогов.

### Обновления
Приложение само проверяет релизы раз в 6 часов (и по пункту меню «Проверить обновления…»). Обновление ставится без повторной выдачи прав.

## Если что-то не так

| Симптом | Что делать |
|---|---|
| Тумблеры включены, а Cmd+Tab не работает | Значок в меню → «Разрешения…» → «Тумблеры включены, но не работает — сбросить». Приложение перезапустится и попросит права заново. |
| Превью окон — просто иконки | Нет Screen Recording. Меню → «Разрешения…». После выдачи приложение перезапустится само. |
| Приложения нет в списке System Settings | Меню → «Разрешения…» → «Открыть настройки…» — это и регистрирует приложение в списке. |
| После перезагрузки Cmd+Tab снова системный | Приложение не запущено. Автозапуск включается при первой установке; проверь меню → «Запускать при входе». |

## Почему раньше был «пиздец» и что изменилось в 1.1.0

Версии 1.0.x подписывались **ad-hoc**. Для macOS это значит «сигнатура = хеш конкретного бинарника»: каждая новая сборка — новое приложение для системы разрешений (TCC). Тумблеры в System Settings оставались включёнными, но относились к старому бинарнику — Cmd+Tab молча переставал работать после каждого обновления. Плюс arm64-only бинарник с minOS 14 и установка перетаскиванием из dmg, после которой Gatekeeper мог запускать приложение из случайного read-only пути (translocation), где права тоже не держатся.

Теперь:
- **Стабильная подпись** — сертификат `CmdTabSwitcher Local Dev`. Designated requirement = `identifier "com.local.cmdtabswitcher" and certificate leaf = H"f086…"`, одинаковый для всех сборок → права переживают обновления на любом Маке.
- **Universal binary** (arm64 + x86_64), minOS 13.0.
- **.pkg-инсталлер** — файлы, положенные Installer'ом, не получают карантин, так что Gatekeeper никогда не трогает само приложение (нет «повреждено», нет translocation). Старая версия убивается и удаляется, бандл отдаётся пользователю (чтобы автообновление работало без пароля), приложение запускается само.
- **Окно разрешений** с живым статусом ✓/✗, кнопками прямо в нужную вкладку настроек, авто-закрытием и авто-перезапуском после выдачи Screen Recording.
- **Самолечение TCC** — если приложение видит, что право не действует, оно один раз на сборку сбрасывает свою запись (`tccutil reset`), чтобы «висящий» тумблер от старой подписи не мешал выдать право заново. То же делает preinstall в pkg для апгрейдов с 1.0.x.
- **Self-install** — запущенное из dmg / Загрузок / translocation-пути приложение само переносит себя в /Applications и перезапускается оттуда.
- Один экземпляр: при запуске убиваются старые копии.

## Сборка из исходников

```bash
./build.sh            # Build/CmdTabSwitcher.app (universal, signed)
./build.sh --install  # + в /Applications и запустить
./make-pkg.sh         # Build/CmdTabSwitcher-<ver>.pkg
./make-dmg.sh         # Build/CmdTabSwitcher-<ver>.dmg
./release.sh 1.2.0    # всё вместе + commit/tag/push + GitHub release (нужен gh auth)
```

### Сертификат

`build.sh` подписывает identity **`CmdTabSwitcher Local Dev`** из Keychain. **Его нельзя терять**: новая подпись = новое приложение для TCC у всех пользователей (ровно та проблема, что была в 1.0.x). Сделай бэкап: Keychain Access → сертификат + приватный ключ → экспорт в `.p12` (файл в `.gitignore`).

Если сертификата нет (новая машина) — восстанови из `.p12` (двойной клик по файлу). Создавать новый — только если бэкапа нет; тогда у всех пользователей права сбросятся один раз (приложение само это переживёт через «самолечение», но попросит права заново):

```bash
cat > codesign.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = CmdTabSwitcher Local Dev
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config codesign.cnf -keyout key.pem -out cert.pem
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "CmdTabSwitcher Local Dev" -out CmdTabSwitcherLocalDev.p12
security import CmdTabSwitcherLocalDev.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
```
