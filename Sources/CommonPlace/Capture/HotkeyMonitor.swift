import AppKit
import CommonPlaceKit

/// Watches for the capture keys (both ⌘ by default; Settings), in any app
/// (a global monitor, which needs Accessibility) and in CommonPlace itself
/// (a local one).
@MainActor
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()
    static let keysDefault = "captureKeys"

    /// The chosen keys (UserDefaults `captureKeys`).
    static var keys: CaptureKeys {
        get { CaptureKeys(rawValue: UserDefaults.standard.string(forKey: keysDefault) ?? "") ?? .bothCommands }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: keysDefault)
            shared.start()
        }
    }

    private var gesture = HotkeyMonitor.keys.gesture
    private var monitors: [Any] = []
    var onGesture: (() -> Void)?
    /// Which of the two keys are down now (the library's key caps sink with them).
    let held = HeldKeys()

    var isRunning: Bool { !monitors.isEmpty }

    /// Start watching; call again once Accessibility is granted (a global
    /// monitor added before then receives nothing).
    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        gesture = Self.keys.gesture
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let flags = UInt64(event.modifierFlags.rawValue)
            if let gesture {
                let left = flags & gesture.left != 0, right = flags & gesture.right != 0
                if held.left != left { held.left = left }
                if held.right != right { held.right = right }
            }
            if gesture?.flagsChanged(flags) == true { onGesture?() }
        case .keyDown:
            if Self.keys == .shortcut, CaptureKeys.isShortcut(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) {
                onGesture?()
            }
            gesture?.keyDown()
        default:
            break
        }
    }
}

/// The two capture keys held down, as they change.
@MainActor
final class HeldKeys: ObservableObject {
    @Published var left = false
    @Published var right = false
}
