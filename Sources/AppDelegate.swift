import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, HotkeyMonitorDelegate, SwitcherOverlayDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = HotkeyMonitor()
    private let overlay = SwitcherOverlay()
    private let tracker = WindowTracker()
    private var pollTimer: Timer?
    private var updateTimer: Timer?
    private var updateMenuItem: NSMenuItem?
    private var windows: [WindowInfo] = []
    private var selectedIndex = 0
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // TCC's Screen Recording (and sometimes Accessibility) prompt/registration
        // is unreliable for a pure LSUIElement/accessory app that's never the
        // frontmost application. Briefly become a regular, activated app while
        // we ask, then drop back to menu-bar-only once the request is filed.
        // The extra delay before asking gives macOS time to actually settle
        // the activation — asking in the same runloop tick as activate()
        // is exactly when this has been unreliable (needing a manual "+"
        // add in Settings afterwards).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.requestPermissions()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NSApp.setActivationPolicy(.accessory)
        }

        tracker.start()
        monitor.delegate = self
        monitor.start()
        overlay.delegate = self

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
                    DispatchQueue.main.async { self.updateMenuItem?.title = "Обновлений нет (v\(Updater.currentVersion()))" }
                }
                return
            }
            NSLog("CmdTabSwitcher: update v\(release.version) found, installing…")
            DispatchQueue.main.async { self.updateMenuItem?.title = "Устанавливаю v\(release.version)…" }
            Updater.downloadAndInstall(release) { success in
                NSLog("CmdTabSwitcher: update install \(success ? "succeeded, relaunching" : "failed")")
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.on.square.dashed", accessibilityDescription: "CmdTabSwitcher")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "CmdTab Switcher", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

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
        menu.addItem(withTitle: "Открыть доступ Accessibility…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Открыть доступ Screen Recording…", action: #selector(openScreenRecordingSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    private func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("CmdTabSwitcher: Accessibility trusted = \(trusted)")

        requestScreenCaptureAccess(attempt: 1)
        // A second attempt a beat later — belt-and-suspenders for the case
        // where the first one lands before the app has fully settled as the
        // active app and gets silently dropped (the exact scenario that
        // ends with someone having to manually hit "+" in Settings).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.requestScreenCaptureAccess(attempt: 2)
        }
    }

    private func requestScreenCaptureAccess(attempt: Int) {
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        NSLog("CmdTabSwitcher: [attempt \(attempt)] Screen Recording pre-granted = \(hasScreenCapture)")
        let granted = CGRequestScreenCaptureAccess()
        NSLog("CmdTabSwitcher: [attempt \(attempt)] Screen Recording request result = \(granted)")

        // Two different capture APIs, since which one reliably registers the
        // app in System Settings' Screen Recording list has varied across
        // macOS versions in testing.
        if CGDisplayCreateImage(CGMainDisplayID()) != nil {
            NSLog("CmdTabSwitcher: [attempt \(attempt)] forced display capture succeeded")
        } else {
            NSLog("CmdTabSwitcher: [attempt \(attempt)] forced display capture returned nil")
        }
        if let windowID = WindowLister.listWindows(excludingPID: ownPID).first?.windowID,
           CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming]) != nil {
            NSLog("CmdTabSwitcher: [attempt \(attempt)] forced window capture succeeded")
        }
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

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
