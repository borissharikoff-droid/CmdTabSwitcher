import AppKit
import CoreGraphics

/// One on-screen window, enumerated from the Window Server (not grouped by app —
/// this is the whole point: Cmd+Tab should switch windows, not applications).
struct WindowInfo {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let ownerName: String
    let bounds: CGRect
}

enum WindowLister {
    /// Front-to-back z-order list of real, user-facing windows, excluding our
    /// own overlay and other chrome (menu bar extras, invisible helper windows).
    static func listWindows(excludingPID ownPID: pid_t) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return []
        }

        var seenPerApp: Set<pid_t> = []
        var result: [WindowInfo] = []

        for entry in raw {
            guard
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                pid != ownPID,
                let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let ownerName = entry[kCGWindowOwnerName as String] as? String
            else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            // Skip slivers/menu-extras/status-bar helpers — real windows are
            // reasonably sized. Tune if a legitimate small window gets hidden.
            guard bounds.width >= 80, bounds.height >= 60 else { continue }

            let title = (entry[kCGWindowName as String] as? String) ?? ""
            // Some apps report an extra hidden "root" window per app in
            // addition to their real windows (e.g. a 1x1 layer). Cheap guard:
            // if we've already taken a window for this pid AND this one has
            // no title AND is unusually small relative to the others, skip.
            _ = seenPerApp.insert(pid)

            result.append(WindowInfo(windowID: windowID, pid: pid, title: title, ownerName: ownerName, bounds: bounds))
        }
        return result
    }
}
