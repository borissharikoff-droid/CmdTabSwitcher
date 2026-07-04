import AppKit
import CoreGraphics

protocol HotkeyMonitorDelegate: AnyObject {
    /// Cmd+Tab (or Cmd+Shift+Tab) was pressed. `reverse` = Shift was held.
    func hotkeyMonitor(_ monitor: HotkeyMonitor, tabPressedReverse reverse: Bool)
    /// Cmd was released — finalize the current selection.
    func hotkeyMonitorCommandReleased(_ monitor: HotkeyMonitor)
    /// Esc was pressed while the switcher is open — cancel, keep current window.
    func hotkeyMonitorCancelled(_ monitor: HotkeyMonitor)
}

/// Intercepts the physical Cmd+Tab keystroke system-wide via a Quartz Event
/// Tap, swallowing it so macOS's built-in app switcher never sees it.
/// Requires Accessibility permission (System Settings → Privacy & Security).
final class HotkeyMonitor {
    weak var delegate: HotkeyMonitorDelegate?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cmdHeld = false

    private static let tabKeyCode: Int64 = 48
    private static let escKeyCode: Int64 = 53

    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("CmdTabSwitcher: failed to create event tap — Accessibility permission missing")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that's too slow or if the user toggles
        // Accessibility off/on — re-enable rather than silently going dead.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            let cmdNow = event.flags.contains(.maskCommand)
            if cmdHeld, !cmdNow {
                cmdHeld = false
                delegate?.hotkeyMonitorCommandReleased(self)
            }
            cmdHeld = cmdNow
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == Self.escKeyCode, cmdHeld {
            delegate?.hotkeyMonitorCancelled(self)
            return nil
        }

        guard keyCode == Self.tabKeyCode, event.flags.contains(.maskCommand) else {
            return Unmanaged.passRetained(event)
        }

        delegate?.hotkeyMonitor(self, tabPressedReverse: event.flags.contains(.maskShift))
        return nil // swallow — macOS's own app switcher must never see this
    }
}
