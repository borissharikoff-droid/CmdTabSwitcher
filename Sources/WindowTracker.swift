import AppKit
import ApplicationServices

/// Tracks two things live, across every app on screen (not just the active one):
///
/// 1. A true most-recently-used order of *individual windows* — updated via
///    app activation and, within the active app, an AX "focused window
///    changed" observer, so switching between two windows of the same app
///    (e.g. two Cursor windows) bumps correctly too.
///
/// 2. A "dirty" set of windows that changed *while they weren't focused* —
///    detected via each window's AX "title changed" notification. This is a
///    generic, no-per-app-integration proxy for "something happened here":
///    a finished agent response, a completed shell command, a new chat
///    message, a finished build — most apps reflect that kind of state in
///    their window title sooner or later. Cleared the moment that window
///    actually becomes focused (by any means — the switcher or a direct
///    click), matching "highlighted until you've looked at it".
final class WindowTracker {
    private(set) var mru: [CGWindowID] = [] // most-recent-first
    private(set) var dirty: Set<CGWindowID> = []
    private var currentFocusedWindowID: CGWindowID?

    private var pidObservers: [pid_t: AXObserver] = [:]
    private var titleObservedWindowIDs: Set<CGWindowID> = []

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let front = NSWorkspace.shared.frontmostApplication {
            ensureObserver(for: front.processIdentifier)
            bumpCurrentlyFocusedWindow(pid: front.processIdentifier)
        }
    }

    /// Call whenever a fresh on-screen window list is available (switcher
    /// opened, or the periodic poll in AppDelegate) so we pick up brand-new
    /// windows/apps and drop bookkeeping for ones that closed.
    func trackWindows(_ windows: [WindowInfo]) {
        for pid in Set(windows.map(\.pid)) {
            ensureObserver(for: pid)
        }

        for window in windows where !titleObservedWindowIDs.contains(window.windowID) {
            guard let observer = pidObservers[window.pid],
                  let axWindow = axWindowElement(pid: window.pid, windowID: window.windowID)
            else { continue }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let err = AXObserverAddNotification(observer, axWindow, kAXTitleChangedNotification as CFString, refcon)
            if err == .success {
                titleObservedWindowIDs.insert(window.windowID)
            }
        }

        let liveIDs = Set(windows.map(\.windowID))
        titleObservedWindowIDs.formIntersection(liveIDs)
        dirty.formIntersection(liveIDs)
        mru.removeAll { !liveIDs.contains($0) }
    }

    /// Second, independent "something happened" signal: macOS Dock badges.
    /// A lot of apps that never touch their window title (chat apps' unread
    /// counts, background task completion badges, etc.) still set a Dock
    /// badge — which is exposed publicly via Accessibility as each Dock
    /// item's "AXStatusLabel" attribute. Small BFS over the Dock's own AX
    /// tree (it's tiny — a few dozen icons), matched back to windows by
    /// owning app name.
    func pollDockBadges(currentWindows: [WindowInfo]) {
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return }
        let root = AXUIElementCreateApplication(dockApp.processIdentifier)

        var queue: [AXUIElement] = [root]
        var badgedAppNames: Set<String> = []
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let element = queue.removeFirst()
            visited += 1

            var statusRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &statusRef) == .success,
               let status = statusRef as? String, !status.isEmpty {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                if let name = titleRef as? String {
                    badgedAppNames.insert(name)
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        guard !badgedAppNames.isEmpty else { return }

        let byOwnerName = Dictionary(grouping: currentWindows, by: { $0.ownerName })
        for appName in badgedAppNames {
            guard let windowsForApp = byOwnerName[appName] else { continue }
            for w in windowsForApp where w.windowID != currentFocusedWindowID {
                dirty.insert(w.windowID)
            }
        }
    }

    /// Call right after we (or the user, elsewhere) focus a window — bumps
    /// MRU immediately and clears its "something changed" badge, without
    /// waiting on the AX notification round-trip.
    func markUsed(_ windowID: CGWindowID) {
        mru.removeAll { $0 == windowID }
        mru.insert(windowID, at: 0)
        dirty.remove(windowID)
        currentFocusedWindowID = windowID
    }

    /// Reorders `current` windows by recency; anything never tracked yet is
    /// appended at the end untouched.
    func ordered(_ current: [WindowInfo]) -> [WindowInfo] {
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })
        var seen = Set<CGWindowID>()
        var result: [WindowInfo] = []
        for wid in mru {
            if let w = byID[wid] {
                result.append(w)
                seen.insert(wid)
            }
        }
        for w in current where !seen.contains(w.windowID) {
            result.append(w)
        }
        return result
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        ensureObserver(for: app.processIdentifier)
        bumpCurrentlyFocusedWindow(pid: app.processIdentifier)
    }

    private func ensureObserver(for pid: pid_t) {
        guard pidObservers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
                .handle(notification: notification as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)

        pidObservers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func bumpCurrentlyFocusedWindow(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success else { return }
        handle(notification: kAXFocusedWindowChangedNotification as String, element: winRef as! AXUIElement)
    }

    private func handle(notification: String, element: AXUIElement) {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success else { return }

        if notification == kAXFocusedWindowChangedNotification as String {
            markUsed(wid)
        } else if notification == kAXTitleChangedNotification as String {
            if wid != currentFocusedWindowID {
                dirty.insert(wid)
            }
        }
    }

    private func axWindowElement(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else { return nil }
        return axWindows.first { candidate in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(candidate, &wid) == .success && wid == windowID
        }
    }
}
