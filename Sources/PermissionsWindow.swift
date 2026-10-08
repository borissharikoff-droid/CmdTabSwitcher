import AppKit

/// First-run / "something's off" window: shows the two permissions as rows
/// with a live ✓/✗ status and a button that jumps straight to the right pane
/// in System Settings. Polls every second and closes itself once both are
/// granted, so the user never has to guess whether the toggle "took".
final class PermissionsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var pollTimer: Timer?
    /// Only auto-close when the window was opened because something was
    /// missing — if everything's already granted (opened from the menu to
    /// check), it stays until the user closes it.
    private var autoCloseWhenGranted = false
    private let accessibilityRow = PermissionRow(
        title: "Accessibility (Универсальный доступ)",
        detail: "Нужно, чтобы перехватывать Cmd+Tab и переключать окна."
    )
    private let screenRecordingRow = PermissionRow(
        title: "Screen Recording (Запись экрана)",
        detail: "Нужно для живых превью окон. Без него будут просто иконки."
    )

    /// Called every poll with the current state, so the owner can react
    /// (start the event tap, relaunch after a Screen Recording grant, …).
    var onStatusChange: ((_ accessibility: Bool, _ screenRecording: Bool) -> Void)?

    func show() {
        if window == nil {
            window = makeWindow()
        }
        autoCloseWhenGranted = !Permissions.allGranted
        refresh()
        // A menu-bar-only (accessory) app can't become frontmost, and TCC
        // prompts filed from a non-frontmost app are flaky — be a regular app
        // for as long as this window is up.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func close() {
        window?.orderOut(nil)
        didHide()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Red close button path — same teardown as `close()`.
    func windowWillClose(_ notification: Notification) {
        didHide()
    }

    private func didHide() {
        pollTimer?.invalidate()
        pollTimer = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let ax = Permissions.accessibilityGranted
        let sr = Permissions.screenRecordingGranted
        accessibilityRow.granted = ax
        screenRecordingRow.granted = sr
        onStatusChange?(ax, sr)
        if ax && sr && autoCloseWhenGranted {
            autoCloseWhenGranted = false
            // Give the user a beat to see both ticks, then get out of the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, Permissions.allGranted else { return }
                self.close()
            }
        }
    }

    // MARK: - UI

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "CmdTab Switcher — настройка"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self

        let content = NSView()
        window.contentView = content

        let heading = NSTextField(labelWithString: "Дай два разрешения — и всё заработает")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        let intro = NSTextField(wrappingLabelWithString:
            "Нажми кнопку справа — откроется нужная вкладка System Settings. Включи там тумблер напротив CmdTabSwitcher. Окно само закроется, когда оба разрешения будут выданы.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        accessibilityRow.onOpen = {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        }
        screenRecordingRow.onOpen = {
            Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
        }

        let relaunchButton = NSButton(title: "Перезапустить приложение", target: self, action: #selector(relaunchApp))
        relaunchButton.bezelStyle = .rounded
        relaunchButton.controlSize = .small
        relaunchButton.font = .systemFont(ofSize: 11)

        let resetButton = NSButton(title: "Тумблеры включены, но не работает — сбросить", target: self, action: #selector(resetPermissions))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: 11)

        let buttons = NSStackView(views: [relaunchButton, resetButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let hint = NSTextField(wrappingLabelWithString:
            "Держи Cmd и жми Tab — переключение между окнами (не приложениями). Приложение живёт в строке меню (значок с квадратиками).")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [heading, intro, accessibilityRow, screenRecordingRow, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            intro.widthAnchor.constraint(equalToConstant: 480),
            hint.widthAnchor.constraint(equalToConstant: 480),
            accessibilityRow.widthAnchor.constraint(equalToConstant: 480),
            screenRecordingRow.widthAnchor.constraint(equalToConstant: 480),
        ])
        return window
    }

    @objc private func relaunchApp() {
        Relauncher.relaunch(appAt: Bundle.main.bundlePath)
    }

    @objc private func resetPermissions() {
        let alert = NSAlert()
        alert.messageText = "Сбросить разрешения CmdTabSwitcher?"
        alert.informativeText = "Старые записи в System Settings будут удалены, приложение перезапустится и попросит разрешения заново. Это лечит ситуацию «тумблер включён, а Cmd+Tab не работает» после обновления."
        alert.addButton(withTitle: "Сбросить и перезапустить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Permissions.reset()
        Relauncher.relaunch(appAt: Bundle.main.bundlePath)
    }
}

/// One line: status glyph, title + description, "Открыть настройки" button.
private final class PermissionRow: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let button: NSButton
    var onOpen: (() -> Void)?

    var granted: Bool = false {
        didSet {
            statusLabel.stringValue = granted ? "✅" : "❌"
            button.isEnabled = !granted
            button.title = granted ? "Готово" : "Открыть настройки…"
        }
    }

    init(title: String, detail: String) {
        button = NSButton(title: "Открыть настройки…", target: nil, action: nil)
        super.init(frame: .zero)

        statusLabel.font = .systemFont(ofSize: 18)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(openTapped)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [statusLabel, text, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        granted = false
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openTapped() {
        onOpen?()
    }
}
