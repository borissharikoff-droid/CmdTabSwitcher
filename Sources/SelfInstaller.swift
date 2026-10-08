import AppKit

/// Quits this process and starts the app bundle at `path` a moment later.
/// Done through a tiny detached shell script because a running app can't
/// launch a second copy of itself with the same bundle ID — LaunchServices
/// would just re-activate the running one. Works the same whether the app was
/// started by hand or by the "launch at login" registration.
enum Relauncher {
    static func relaunch(appAt path: String, cleanup: [String] = []) {
        var script = "#!/bin/sh\nsleep 1\nopen -a \"\(path)\"\n"
        for item in cleanup {
            script += "rm -rf \"\(item)\"\n"
        }
        let scriptPath = "/tmp/cmdtabswitcher-relaunch-\(ProcessInfo.processInfo.processIdentifier).sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptPath]
            try process.run()
        } catch {
            NSLog("CmdTabSwitcher: relaunch script failed: \(error)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}

/// Makes sure the running copy is the one in /Applications.
///
/// The .pkg installer always puts the app there, so this is a safety net for
/// anyone who grabbed the bare .zip/.app and double-clicked it from the
/// Downloads folder or straight off a mounted .dmg: Gatekeeper then runs the
/// app from a randomized read-only "translocation" path, which (a) changes on
/// every launch, so Accessibility/Screen Recording grants never stick, and
/// (b) breaks "launch at login". Copying ourselves to /Applications once and
/// relaunching from there fixes both.
enum SelfInstaller {
    static let installPath = "/Applications/CmdTabSwitcher.app"

    /// Returns `true` when the app is being moved and will relaunch — the
    /// caller must stop its own launch sequence in that case.
    static func relocateIfNeeded() -> Bool {
        let current = Bundle.main.bundlePath
        guard current != installPath, isTemporaryLocation(current) else { return false }
        NSLog("CmdTabSwitcher: running from \(current) — moving to \(installPath)")

        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: installPath) {
                try fm.removeItem(atPath: installPath)
            }
            try fm.copyItem(atPath: current, toPath: installPath)
        } catch {
            NSLog("CmdTabSwitcher: could not copy to /Applications: \(error)")
            showManualMoveAlert()
            return false
        }

        // The copy inherited the download's quarantine flag; drop it so the
        // fresh copy isn't translocated or re-screened by Gatekeeper again.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", installPath]
        try? xattr.run()
        xattr.waitUntilExit()

        Relauncher.relaunch(appAt: installPath)
        return true
    }

    /// Terminates any other running copy of this app (e.g. an old version still
    /// alive while a newer one was just opened) so there's never two event
    /// taps fighting over Cmd+Tab.
    static func terminateOtherInstances() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Permissions.bundleID)
            .filter { $0.processIdentifier != ownPID }
        for app in others {
            NSLog("CmdTabSwitcher: terminating other instance pid \(app.processIdentifier)")
            app.terminate()
        }
    }

    /// Only places we *know* are wrong to run from. Anything else (a dev build
    /// in the repo's Build/ folder, ~/Applications, …) is left alone.
    private static func isTemporaryLocation(_ path: String) -> Bool {
        if path.hasPrefix("/Volumes/") { return true } // mounted .dmg
        if path.contains("/AppTranslocation/") { return true } // Gatekeeper's randomized copy
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        if let downloads, path.hasPrefix(downloads + "/") { return true }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
        if let desktop, path.hasPrefix(desktop + "/") { return true }
        return false
    }

    private static func showManualMoveAlert() {
        let alert = NSAlert()
        alert.messageText = "Перетащи CmdTabSwitcher в папку «Программы»"
        alert.informativeText = "Не удалось скопировать приложение в /Applications автоматически. Перетащи CmdTabSwitcher.app в папку «Программы» (Applications) и запусти его оттуда — иначе macOS будет сбрасывать выданные разрешения."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
