import CoreGraphics
import Foundation

/// How the user keeps a window.
public enum CaptureKeys: String, CaseIterable, Sendable {
    /// Left ⌘ and right ⌘ together (the default).
    case bothCommands
    /// Left ⌥ and right ⌥ together.
    case bothOptions
    /// ⌃⌥⌘K, for keyboards without a right ⌘ or for those who prefer a shortcut.
    case shortcut

    public var title: String {
        switch self {
        case .bothCommands: return "Both ⌘ keys"
        case .bothOptions: return "Both ⌥ keys"
        case .shortcut: return "⌃⌥⌘K"
        }
    }

    /// The gesture for a two-sided choice; nil for the shortcut.
    public var gesture: BothSidesGesture? {
        switch self {
        case .bothCommands: return BothSidesGesture(left: BothSidesGesture.leftCommand, right: BothSidesGesture.rightCommand,
                                                    others: BothSidesGesture.shift | BothSidesGesture.control | BothSidesGesture.option | BothSidesGesture.function)
        case .bothOptions: return BothSidesGesture(left: BothSidesGesture.leftOption, right: BothSidesGesture.rightOption,
                                                   others: BothSidesGesture.shift | BothSidesGesture.control | BothSidesGesture.command | BothSidesGesture.function)
        case .shortcut: return nil
        }
    }

    /// The keys as they are drawn on key caps.
    public var caps: [String] {
        switch self {
        case .bothCommands: return ["⌘", "⌘"]
        case .bothOptions: return ["⌥", "⌥"]
        case .shortcut: return ["⌃", "⌥", "⌘", "K"]
        }
    }

    /// The shortcut's key (K) and modifiers (⌃⌥⌘, NSEvent raw values).
    public static let shortcutKeyCode: UInt16 = 40
    public static let shortcutModifiers: UInt64 = BothSidesGesture.control | BothSidesGesture.option | BothSidesGesture.command

    /// Whether a key press is the shortcut: K with exactly ⌃⌥⌘ (Shift, Fn off).
    public static func isShortcut(keyCode: UInt16, flags: UInt64) -> Bool {
        let relevant = flags & (BothSidesGesture.shift | BothSidesGesture.control | BothSidesGesture.option
                                | BothSidesGesture.command | BothSidesGesture.function)
        return keyCode == shortcutKeyCode && relevant == shortcutModifiers
    }
}

/// Both keys of one modifier (left and right) pressed together, nothing
/// else: the capture gesture.
///
/// Fed every modifier change (`flagsChanged`: the device-dependent flags,
/// which tell left from right) and every key press.  Fires once when left
/// and right are both down with no other modifier and no key typed since
/// the first went down; again only after both are released.  A shortcut
/// typed with one of them never fires.
public struct BothSidesGesture: Sendable {
    /// IOKit's device flags (NX_DEVICELCMDKEYMASK and friends).
    public static let leftCommand: UInt64 = 0x0000_0008
    public static let rightCommand: UInt64 = 0x0000_0010
    public static let leftOption: UInt64 = 0x0000_0020
    public static let rightOption: UInt64 = 0x0000_0040
    /// NSEvent.ModifierFlags raw values.
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let function: UInt64 = 0x0080_0000

    public let left: UInt64
    public let right: UInt64
    /// Any of these held spoils the gesture.
    public let others: UInt64

    private var spoiled = false
    private var fired = false
    /// Left or right is down now.
    private var holding = false

    public init(left: UInt64, right: UInt64, others: UInt64) {
        self.left = left
        self.right = right
        self.others = others
    }

    /// A modifier changed; true when this change completes the gesture.
    public mutating func flagsChanged(_ flags: UInt64) -> Bool {
        let left = flags & self.left != 0
        let right = flags & self.right != 0
        holding = left || right
        if !left && !right {
            // Both released: ready again.
            spoiled = false
            fired = false
            return false
        }
        if flags & others != 0 { spoiled = true }
        guard left && right, !spoiled, !fired else { return false }
        fired = true
        return true
    }

    /// A key was typed.  While one of the two keys is held, that was a
    /// shortcut (⌘C), not the gesture; typing with neither held changes
    /// nothing (it used to spoil the next gesture: the first ⌘⌘ after any
    /// typing was ignored).
    public mutating func keyDown() {
        if holding { spoiled = true }
    }
}

/// One on-screen window, as `CGWindowListCopyWindowInfo` describes it.
public struct WindowEntry: Equatable, Sendable {
    public var number: Int
    public var pid: Int
    public var owner: String
    public var title: String
    public var layer: Int
    public var x: Double, y: Double, width: Double, height: Double

    public init(number: Int, pid: Int, owner: String, title: String = "", layer: Int = 0,
                x: Double, y: Double, width: Double, height: Double) {
        self.number = number
        self.pid = pid
        self.owner = owner
        self.title = title
        self.layer = layer
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Which window "the window you are in" is.
public enum WindowChoice {
    /// Narrower or shorter than this (points), a window is a bar, not one you work in.
    public static let minimumSide: Double = 100

    /// Of the frontmost app (else of every app), never a bar, never
    /// `excludingPID` (CommonPlace's own windows); `windows` is front to back.
    ///
    /// With `focusedFrame` (the frame Accessibility reports for the app's
    /// focused window, top-left screen coordinates), the window that
    /// overlaps it most.  Without it, the frontmost titled window, else the
    /// largest.
    ///
    /// Apps draw toolbars and pop-ups as separate windows above their
    /// content.  Comet: its tab strip and toolbar (1512 × 43, × 42 and × 121,
    /// untitled) and its "Restore pages?" bubble (320 × 148, titled) all sit
    /// above the page window; neither "the topmost" nor "the topmost titled"
    /// window is the page, the window the focused one overlaps most is.
    public static func pick(_ windows: [WindowEntry], frontmostPID: Int?, excludingPID: Int? = nil,
                            focusedFrame: CGRect? = nil) -> WindowEntry? {
        let ordinary = windows.filter {
            $0.layer == 0 && !$0.owner.isEmpty && $0.pid != excludingPID
                && $0.width >= minimumSide && $0.height >= minimumSide
        }
        let own = frontmostPID.map { pid in ordinary.filter { $0.pid == pid } } ?? []
        let candidates = own.isEmpty ? ordinary : own
        if let focusedFrame, !own.isEmpty {
            let overlap = { (w: WindowEntry) -> Double in
                let i = CGRect(x: w.x, y: w.y, width: w.width, height: w.height).intersection(focusedFrame)
                return i.isNull ? 0 : Double(i.width * i.height)
            }
            if let best = own.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
                return best
            }
        }
        return candidates.first { !$0.title.isEmpty } ?? candidates.max { $0.width * $0.height < $1.width * $1.height }
    }
}
