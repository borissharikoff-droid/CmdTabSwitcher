import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, HotkeyMonitorDelegate, SwitcherOverlayDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = HotkeyMonitor()
    private let overlay = SwitcherOverlay()
    private let tracker = WindowTracker()
    private let permissionsWindow = PermissionsWindow()
    private var pollTimer: Timer?
    private var permissionPollTimer: Timer?
    private var updateTimer: Timer?
    private var updateMenuItem: NSMenuItem?
    private var permissionsMenuItem: NSMenuItem?
    private var windows: [WindowInfo] = []
    private var selectedIndex = 0
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Screen Recording state at launch. A grant only takes effect in a fresh
    /// process, so if this flips from false to true we relaunch ourselves.
    private var screenRecordingAtLaunch = false
    private var relaunchScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy only (an older version may still be running) — and it has
        // to go *before* a possible relocation below, or `open` would just
        // re-activate the old process instead of launching the new bundle.
        SelfInstaller.terminateOtherInstances()
        // Running from a .dmg / Downloads / Gatekeeper translocation path?
        // Move to /Applications first — permissions can't stick otherwise.
        // The app quits and comes back from the right place.
        if SelfInstaller.relocateIfNeeded() { return }

        setupStatusItem()
        enableLaunchAtLoginOnFirstRun()
        // Clears "toggle is ON but nothing works" leftovers from older,
        // differently-signed builds — before we look at the state below.
        Permissions.healStaleEntriesIfNeeded()

        screenRecordingAtLaunch = Permissions.screenRecordingGranted
        tracker.start()
        monitor.delegate = self
        monitor.start() // fails harmlessly until Accessibility is granted; retried below
        overlay.delegate = self
        startPermissionWatcher()

        if !Permissions.allGranted {
            // Register with TCC right away (that's what makes the app appear in
            // the System Settings lists) and show the guide. Done from a
            // regular, activated app state — prompts from a never-frontmost
            // menu-bar app are flaky — PermissionsWindow.show() handles that.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPermissionsGuide()
                Permissions.requestAccessibility()
                if !Permissions.screenRecordingGranted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        Permissions.requestScreenRecording()
                    }
                }
            }
        } else if CommandLine.arguments.contains("--permissions") {
            // `open -a CmdTabSwitcher --args --permissions` — show the status
            // window even when everything is fine (support / screenshots).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPermissionsGuide()
            }
        }

        // Keep title-change watchers current even while the switcher is
        // closed, so "something happened in a background window" is caught
        // promptly instead of only the moment you next press Cmd+Tab.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let listed = WindowLister.listWindows(excludingPID: self.ownPID)
            self.tracker.trackWindows(listed)
            self.tracker.pollDockBadges(currentWindows: listed)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkForUpdates(silent: true) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(silent: true)
        }
    }

    private func checkForUpdates(silent: Bool) {
        Updater.checkForUpdate { [weak self] release in
            guard let self else { return }
            guard let release, Updater.isNewer(release.version, than: Updater.currentVersion()) else {
                NSLog("CmdTabSwitcher: up to date (v\(Updater.currentVersion()))")
                if !silent {
                    DispatchQueue.main.async {
                        self.updateMenuItem?.title = "Обновлений нет (v\(Updater.currentVersion()))"
                    }
                    self.resetUpdateMenuItemLater()
                }
                return
            }
            NSLog("CmdTabSwitcher: update v\(release.version) found, downloading…")
            DispatchQueue.main.async { self.updateMenuItem?.title = "Скачиваю v\(release.version)… 0%" }
            Updater.downloadAndInstall(release) { [weak self] fraction in
                // Already on the main thread (Updater dispatches it there),
                // but stay defensive about that contract.
                let percent = Int((fraction * 100).rounded())
                if fraction >= 0.999 {
                    self?.updateMenuItem?.title = "Устанавливаю v\(release.version)…"
                } else {
                    self?.updateMenuItem?.title = "Скачиваю v\(release.version)… \(percent)%"
                }
            } completion: { [weak self] success in
                NSLog("CmdTabSwitcher: update install \(success ? "succeeded, relaunching" : "failed")")
                guard let self else { return }
                DispatchQueue.main.async {
                    if success {
                        // The app quits and relaunches itself within a fraction
                        // of a second after this (see Updater), so this mostly
                        // matters for the brief instant before that happens.
                        self.updateMenuItem?.title = "Установлено v\(release.version) — перезапуск…"
                    } else {
                        self.updateMenuItem?.title = "Не удалось установить обновление"
                        self.resetUpdateMenuItemLater()
                    }
                }
            }
        }
    }

    /// Without this, a failed/finished check left the menu item permanently
    /// stuck on whatever status text it last showed (the reported bug) —
    /// put it back to the actionable "Проверить обновления…" after a beat.
    private func resetUpdateMenuItemLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.updateMenuItem?.title = "Проверить обновления…"
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.on.square.dashed", accessibilityDescription: "CmdTabSwitcher")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "CmdTab Switcher v\(Updater.currentVersion())", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        let permissions = NSMenuItem(title: "Разрешения…", action: #selector(showPermissionsGuide), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        permissionsMenuItem = permissions

        let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let update = NSMenuItem(title: "Проверить обновления…", action: #selector(checkForUpdatesManually), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        updateMenuItem = update

        menu.addItem(.separator())
        menu.addItem(withTitle: "Перезапустить", action: #selector(relaunch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        refreshPermissionsMenuItem()
    }

    // MARK: - Permissions

    /// Cheap 2s poll (AXIsProcessTrusted / CGPreflightScreenCaptureAccess are
    /// local checks) that reacts to grants made in System Settings while we
    /// run: starts the event tap the moment Accessibility arrives, relaunches
    /// once Screen Recording arrives (it only applies to a fresh process),
    /// and keeps the menu status line current.
    private func startPermissionWatcher() {
        permissionsWindow.onStatusChange = { [weak self] _, _ in self?.reactToPermissionState() }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reactToPermissionState()
        }
    }

    private func reactToPermissionState() {
        if Permissions.accessibilityGranted, !monitor.isRunning {
            monitor.start()
        }
        if !screenRecordingAtLaunch, Permissions.screenRecordingGranted, !relaunchScheduled {
            relaunchScheduled = true
            NSLog("CmdTabSwitcher: Screen Recording granted — relaunching so thumbnails work")
            // Short delay so the permissions window shows the second ✅ before
            // the restart; the system's own "Quit & Reopen" dialog may already
            // have done this for us, in which case we're not running anymore.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Relauncher.relaunch(appAt: Bundle.main.bundlePath)
            }
        }
        refreshPermissionsMenuItem()
    }

    private func refreshPermissionsMenuItem() {
        let ax = Permissions.accessibilityGranted
        let sr = Permissions.screenRecordingGranted
        if ax && sr {
            permissionsMenuItem?.title = "Разрешения: всё выдано ✅"
        } else {
            permissionsMenuItem?.title = "Разрешения: нужна настройка ⚠️"
        }
    }

    @objc private func showPermissionsGuide() {
        permissionsWindow.show()
    }

    /// Cmd+Tab replacement that silently stops working after a reboot (because
    /// it isn't running) reads as "broken" — so default to launching at login
    /// once, on first run. The menu toggle still lets the user turn it off.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetDefaultLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        // Only from the permanent location — registering a copy that lives on
        // a .dmg or in Downloads would point login at a path that disappears.
        guard Bundle.main.bundlePath == SelfInstaller.installPath else { return }
        LaunchAtLogin.isEnabled = true
    }

    /// Double-clicking the app in Finder while it's already running: show the
    /// status window instead of appearing to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPermissionsGuide()
        return false
    }

    // MARK: - HotkeyMonitorDelegate

    func hotkeyMonitor(_ monitor: HotkeyMonitor, tabPressedReverse reverse: Bool) {
        if !overlay.isVisible {
            let listed = WindowLister.listWindows(excludingPID: ownPID)
            tracker.trackWindows(listed)
            windows = tracker.ordered(listed)
            guard !windows.isEmpty else { return }
            selectedIndex = windows.count > 1 ? 1 : 0
            overlay.show(windows: windows, selected: selectedIndex, dirty: tracker.dirty)
        } else {
            guard !windows.isEmpty else { return }
            selectedIndex = reverse
                ? (selectedIndex - 1 + windows.count) % windows.count
                : (selectedIndex + 1) % windows.count
            overlay.updateSelection(selectedIndex)
        }
    }

    func hotkeyMonitorCommandReleased(_ monitor: HotkeyMonitor) {
        guard overlay.isVisible else { return }
        switchToSelected()
    }

    func hotkeyMonitorCancelled(_ monitor: HotkeyMonitor) {
        overlay.hide()
    }

    private func switchToSelected() {
        overlay.hide()
        guard windows.indices.contains(selectedIndex) else { return }
        let target = windows[selectedIndex]
        tracker.markUsed(target.windowID)
        WindowActivator.activate(target)
    }

    // MARK: - SwitcherOverlayDelegate

    func switcherOverlay(_ overlay: SwitcherOverlay, didHoverIndex index: Int) {
        // Real cursor motion while the switcher is open — let the mouse
        // preview a selection, same as another Tab press would.
        guard windows.indices.contains(index) else { return }
        selectedIndex = index
        overlay.updateSelection(index)
    }

    func switcherOverlay(_ overlay: SwitcherOverlay, didClickIndex index: Int) {
        guard windows.indices.contains(index) else { return }
        selectedIndex = index
        switchToSelected()
    }

    func switcherOverlayDidClickOutside(_ overlay: SwitcherOverlay) {
        // Same as Esc — dismiss without switching anywhere. Cmd may still be
        // held down physically; hiding here means the eventual Cmd-release
        // is a no-op too, since hotkeyMonitorCommandReleased bails when the
        // overlay isn't visible.
        overlay.hide()
    }

    // MARK: - Menu actions

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newValue = sender.state != .on
        LaunchAtLogin.isEnabled = newValue
        sender.state = newValue ? .on : .off
    }

    @objc private func checkForUpdatesManually() {
        updateMenuItem?.title = "Проверяю…"
        checkForUpdates(silent: false)
    }

    @objc private func relaunch() {
        Relauncher.relaunch(appAt: Bundle.main.bundlePath)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
