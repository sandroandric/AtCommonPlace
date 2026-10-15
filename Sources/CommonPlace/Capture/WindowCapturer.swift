import AppKit
import ApplicationServices
import CommonPlaceKit
import ScreenCaptureKit

/// Keeps "the window you are in": picks it (`WindowChoice`), captures it
/// with ScreenCaptureKit at full resolution, and reads what macOS knows
/// about it (app, title, the page's URL or the document's path).
enum WindowCapturer {
    enum Failure: Error {
        case noPermission
        case noWindow
        case captureFailed
    }

    struct Shot {
        let capture: Capture
        let png: Data
        let thumbnail: Data
        let image: CGImage
        /// The window's frame in screen points (top-left origin), for the flash.
        let frame: CGRect
    }

    /// The window the user is in, found: its ScreenCaptureKit window, where
    /// it is, and what macOS knows about it (a capture without a picture yet).
    struct Target {
        let window: SCWindow
        let entry: WindowEntry
        /// The app, title, page URL or document; width/height not yet set.
        let capture: Capture
        /// Points to pixels for this window's display.
        let scale: CGFloat
        var frame: CGRect { CGRect(x: entry.x, y: entry.y, width: entry.width, height: entry.height) }
    }

    static func focusedTarget() async throws -> Target {
        guard CGPreflightScreenCaptureAccess() else { throw Failure.noPermission }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        let entries = list.map(entry)
        let frontmost = NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) }
        let focusedFrame = frontmost.flatMap { AccessibilityPlace.focusedWindowFrame(pid: pid_t($0)) }
        guard let chosen = WindowChoice.pick(entries, frontmostPID: frontmost,
                                             excludingPID: Int(ProcessInfo.processInfo.processIdentifier),
                                             focusedFrame: focusedFrame) else {
            throw Failure.noWindow
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { Int($0.windowID) == chosen.number }) else {
            throw Failure.noWindow
        }
        let app = NSRunningApplication(processIdentifier: pid_t(chosen.pid))
        let place = AccessibilityPlace.read(pid: pid_t(chosen.pid))
        let capture = Capture(
            app: app?.localizedName ?? chosen.owner,
            bundleID: app?.bundleIdentifier,
            windowTitle: chosen.title.isEmpty ? (place.title ?? "") : chosen.title,
            url: place.url,
            documentPath: place.documentPath,
            width: 0,
            height: 0
        )
        let scale = CGFloat(SCContentFilter(desktopIndependentWindow: window).pointPixelScale)
        return Target(window: window, entry: chosen, capture: capture, scale: scale)
    }

    /// The whole window at full resolution.
    static func shoot(_ target: Target) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.window.frame.width * target.scale)
        configuration.height = Int(target.window.frame.height * target.scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    static func captureFocusedWindow() async throws -> Shot {
        try await shot(of: try await focusedTarget())
    }

    static func shot(of target: Target) async throws -> Shot {
        let image = try await shoot(target)
        guard let png = Thumbnailer.png(image), let thumbnail = Thumbnailer.jpeg(from: png, maxPixel: 720, quality: 0.82) else {
            throw Failure.captureFailed
        }
        var capture = target.capture
        capture.width = image.width
        capture.height = image.height
        return Shot(capture: capture, png: png, thumbnail: thumbnail, image: image, frame: target.frame)
    }

    static func entry(_ dict: [String: Any]) -> WindowEntry {
        let bounds = dict[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return WindowEntry(
            number: dict[kCGWindowNumber as String] as? Int ?? 0,
            pid: dict[kCGWindowOwnerPID as String] as? Int ?? 0,
            owner: dict[kCGWindowOwnerName as String] as? String ?? "",
            title: dict[kCGWindowName as String] as? String ?? "",
            layer: dict[kCGWindowLayer as String] as? Int ?? 0,
            x: bounds["X"] as? Double ?? 0, y: bounds["Y"] as? Double ?? 0,
            width: bounds["Width"] as? Double ?? 0, height: bounds["Height"] as? Double ?? 0
        )
    }
}

/// What Accessibility says about an app's focused window: its title, the
/// document it shows (`AXDocument`) and, in a browser, the page's URL (the
/// web area's `AXURL`).  Every read is bounded: 200 ms per call, a few
/// hundred elements.
enum AccessibilityPlace {
    struct Place {
        var title: String?
        var url: String?
        var documentPath: String?
    }

    /// The app's focused window's frame (top-left screen coordinates, as
    /// CGWindow bounds are), or nil.
    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let positionValue = value, AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let sizeValue = value, AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func read(pid: pid_t) -> Place {
        guard AXIsProcessTrusted() else { return Place() }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return Place() }
        var place = Place(title: string(window, kAXTitleAttribute))
        if let document = string(window, kAXDocumentAttribute), let url = URL(string: document) {
            if url.isFileURL { place.documentPath = url.path } else { place.url = document }
        }
        if place.url == nil { place.url = webAreaURL(under: window) }
        return place
    }

    /// The first `AXWebArea`'s URL below `root` (breadth first, bounded).
    private static func webAreaURL(under root: AXUIElement) -> String? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let node = queue.removeFirst()
            visited += 1
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &value) == .success {
                    if let url = value as? URL { return url.absoluteString }
                    if let text = value as? String { return text }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.prefix(40))
            }
        }
        return nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
