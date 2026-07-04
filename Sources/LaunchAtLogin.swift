import Foundation

/// Minimal "start at login" via a user LaunchAgent — no extra frameworks,
/// works the same on every macOS version.
enum LaunchAtLogin {
    private static let label = "com.local.cmdtabswitcher"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        get { FileManager.default.fileExists(atPath: plistURL.path) }
        set {
            if newValue { install() } else { uninstall() }
        }
    }

    private static func install() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            _ = shell("/bin/launchctl", ["load", plistURL.path])
        } catch {
            NSLog("CmdTabSwitcher: failed to install LaunchAgent: \(error)")
        }
    }

    private static func uninstall() {
        _ = shell("/bin/launchctl", ["unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}
