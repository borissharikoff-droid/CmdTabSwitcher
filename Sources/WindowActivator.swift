import AppKit
import ApplicationServices

/// Private-but-stable API (used by every AX-based window switcher — Hammerspoon,
/// yabai, etc.) that maps an AXUIElement window straight to its CGWindowID.
/// Public AX API has no such mapping, and title/bounds heuristics fall apart
/// for apps like Cursor/VS Code/Chrome where several windows share one PID
/// and can have identical-looking titles.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Brings a *specific* window to the front — not just "activate the app"
/// (which is a no-op if that app's process is already frontmost, e.g.
/// switching between two windows of the same multi-window app like Cursor).
enum WindowActivator {
    static func activate(_ window: WindowInfo) {
        // Activate the owning process first...
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateAllWindows])

        // ...then, a beat later, raise the *exact* window by CGWindowID. The
        // short delay avoids racing AppKit's own "restore last key window"
        // behavior that activate() can trigger for multi-window apps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            raiseExactWindow(window)
        }
    }

    private static func raiseExactWindow(_ window: WindowInfo) {
        let appElement = AXUIElementCreateApplication(window.pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        let match = axWindows.first { candidate in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(candidate, &wid) == .success && wid == window.windowID
        } ?? axWindows.first { matchesByHeuristic($0, window) }

        guard let match else { return }
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, match)
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateAllWindows])
    }

    /// Fallback for the rare case _AXUIElementGetWindow fails (sandboxed apps,
    /// odd AX trees) — same title/bounds match as before, better than nothing.
    private static func matchesByHeuristic(_ ax: AXUIElement, _ target: WindowInfo) -> Bool {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? ""

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &sizeRef)

        var point = CGPoint.zero
        var size = CGSize.zero
        if let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        }
        if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }

        let boundsClose = abs(point.x - target.bounds.origin.x) < 4
            && abs(point.y - target.bounds.origin.y) < 4
            && abs(size.width - target.bounds.width) < 4
            && abs(size.height - target.bounds.height) < 4

        let titleMatches = !target.title.isEmpty && title == target.title
        return titleMatches || boundsClose
    }
}
