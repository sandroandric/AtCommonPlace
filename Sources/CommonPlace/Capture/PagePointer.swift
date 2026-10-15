import AppKit
import ApplicationServices
import CommonPlaceKit

/// What is under the pointer inside a browser page, by Accessibility.
@MainActor
enum PagePointer {
    /// Browsers whose pages are read for an image or video under the pointer.
    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ChromiumBrowsers.bundleIDs.contains(bundleID) || bundleID == "com.apple.Safari"
            || bundleID == "com.apple.SafariTechnologyPreview" || bundleID == "org.mozilla.firefox"
    }

    private static var asked: Set<pid_t> = []

    /// Ask a Chromium browser for its page tree.  It answers "not
    /// implemented" yet builds the tree (measured in Comet); asked once per
    /// process, when it comes to the front, so the tree is ready by the
    /// time the keys are pressed.
    static func prepare(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, ChromiumBrowsers.bundleIDs.contains(bundleID),
              !asked.contains(app.processIdentifier), AXIsProcessTrusted() else { return }
        asked.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Watch for browsers coming to the front.
    static func startPreparing() {
        if let front = NSWorkspace.shared.frontmostApplication { prepare(front) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { prepare(app) }
        }
    }

    /// The target under the pointer in `app`'s page.  When the browser has
    /// not built its tree yet (only its scroll area answers), it is asked and
    /// read again, for at most ~0.6 s.
    static func target(in app: NSRunningApplication) async -> PageTarget {
        guard isBrowser(app.bundleIdentifier), AXIsProcessTrusted() else { return .window }
        prepare(app)
        let point = pointerLocation()
        for attempt in 0..<4 {
            let chain = chain(at: point, pid: app.processIdentifier)
            let decided = PageTarget.decide(chain)
            if decided != .window || chain.contains(where: { $0.role != "AXScrollArea" && $0.role != "AXGroup" && $0.role != "AXWindow" }) {
                return decided
            }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        return .window
    }

    /// The pointer in top-left screen coordinates (as Accessibility and CGWindow use).
    static func pointerLocation() -> CGPoint {
        let location = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: height - location.y)
    }

    /// The element at `point` and its ancestors (at most 10), when it belongs to `pid`.
    static func chain(at point: CGPoint, pid: pid_t) -> [PointerNode] {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return [] }
        var owner: pid_t = 0
        AXUIElementGetPid(hit, &owner)
        guard owner == pid else { return [] }
        var nodes: [PointerNode] = []
        var current: AXUIElement? = hit
        while let element = current, nodes.count < 10 {
            nodes.append(PointerNode(
                role: string(element, kAXRoleAttribute) ?? "",
                roleDescription: string(element, kAXRoleDescriptionAttribute) ?? "",
                title: string(element, kAXTitleAttribute) ?? "",
                description: string(element, kAXDescriptionAttribute) ?? "",
                url: url(element),
                frame: frame(element),
                domClasses: strings(element, "AXDOMClassList"),
                domIdentifier: string(element, "AXDOMIdentifier") ?? ""
            ))
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return nodes
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func strings(_ element: AXUIElement, _ attribute: String) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private static func url(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    private static func frame(_ element: AXUIElement) -> CGRect {
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success, let value {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }
}
