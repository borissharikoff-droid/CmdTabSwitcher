import AppKit
import ApplicationServices

/// The two TCC grants the switcher can't work without, plus the handful of
/// system hooks around them (prompting, deep-linking into System Settings,
/// clearing stale entries).
enum Permissions {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.local.cmdtabswitcher"

    /// Needed for the Cmd+Tab event tap and for raising specific windows.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Needed for the live window thumbnails. Optional in the sense that the
    /// switcher still switches without it — cards just show app icons.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

    /// Shows the system "would like to control this computer" prompt (once per
    /// app registration) and makes sure we're listed in the Accessibility pane.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("CmdTabSwitcher: Accessibility trusted = \(trusted)")
    }

    /// Shows the Screen Recording prompt (once) and registers us in that pane.
    /// Unlike Accessibility, a grant here only takes effect in a *fresh*
    /// process — AppDelegate relaunches once it sees the flag flip.
    static func requestScreenRecording() {
        let granted = CGRequestScreenCaptureAccess()
        NSLog("CmdTabSwitcher: Screen Recording request result = \(granted)")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// Deletes this app's rows from the TCC database. Builds up to 1.0.8 were
    /// ad-hoc signed, which ties a grant to that exact binary's hash: after an
    /// update the toggle in System Settings still shows ON, but no longer
    /// applies to the new binary and macOS offers no hint why. Removing the
    /// rows lets the app ask again and the toggle work for real.
    static func reset() {
        reset(service: "Accessibility")
        reset(service: "ScreenCapture")
    }

    /// Automatic version of `reset()`, run once per build on launch: for any
    /// permission that is *not* currently effective, drop whatever row TCC
    /// has for us. A missing row stays missing (nothing lost), a stale row
    /// from an older differently-signed build — the one that shows an ON
    /// toggle that does nothing — gets cleared so the user can simply grant
    /// again. Grants that work are never touched.
    static func healStaleEntriesIfNeeded() {
        let key = "tccHealedForBuild"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        UserDefaults.standard.set(build, forKey: key)
        if !accessibilityGranted { reset(service: "Accessibility") }
        if !screenRecordingGranted { reset(service: "ScreenCapture") }
    }

    private static func reset(service: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            NSLog("CmdTabSwitcher: tccutil reset \(service) → \(process.terminationStatus)")
        } catch {
            NSLog("CmdTabSwitcher: tccutil reset \(service) failed: \(error)")
        }
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
