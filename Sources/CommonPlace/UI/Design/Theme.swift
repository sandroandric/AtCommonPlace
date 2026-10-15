import AppKit
import CoreText
import SwiftUI

/// CommonPlace's look, "Daylight": warm ivory by day, a deep warm black by
/// night; ink in four strengths; one terracotta accent; Fraunces (soft) for
/// what matters and Inter for the interface.  Spacing is on a 4 pt grid;
/// hairlines are one ink at 8%.
enum Theme {
    // MARK: Colour

    static let ground = Color(light: 0xF6F4EE, dark: 0x0D0C0B)
    static let surface = Color(light: 0xFCFBF8, dark: 0x161513)
    static let raised = Color(light: 0xFFFFFF, dark: 0x1D1B19)
    static let well = Color(light: 0xECE9E1, dark: 0x201E1B)
    static let ink = Color(light: 0x1A1915, dark: 0xEEE9E0)
    static let ink2 = Color(light: 0x5E5B53, dark: 0xB3ADA3)
    static let ink3 = Color(light: 0x8A867B, dark: 0x85807A)
    static let ink4 = Color(light: 0xA29E93, dark: 0x5E5A55)
    static let hairline = Color(light: 0x1A1915, dark: 0xEEE9E0, alpha: 0.08)
    static let wash = Color(light: 0x1A1915, dark: 0xEEE9E0, alpha: 0.05)
    static let accent = Color(light: 0xC8643F, dark: 0xE3835C)
    static let accentWash = Color(light: 0xC8643F, dark: 0xE3835C, alpha: 0.12)
    /// Shadows: ink by day, black by night.
    static let shadow = Color(light: 0x1A1915, dark: 0x000000)
    /// Text on the always-dark stage and horizon.
    static let ivory = Color(hex: 0xFCF6EC)
    static let stage = Color(hex: 0x141311)

    // The collage's materials.
    static let clay = Color(hex: 0xD27A56)
    static let oat = Color(hex: 0xE6DCC6)
    static let sage = Color(hex: 0x9FAE8E)
    static let sky = Color(hex: 0xB7C4D3)
    static let yellow = Color(hex: 0xEEC64A)
    static let pencil = Color(hex: 0x4A3A16)

    // MARK: Type

    /// Fraunces, soft (SOFT 100, WONK 0), its optical size following the size.
    static func serif(_ size: CGFloat, italic: Bool = false, weight: CGFloat = 380) -> Font {
        Fonts.font(italic ? .frauncesItalic : .fraunces, size: size,
                   axes: [Fonts.opsz: min(max(size, 9), 144), Fonts.wght: weight, Fonts.soft: 100, Fonts.wonk: 0])
    }

    /// Inter, its optical size following the size.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let value: CGFloat
        switch weight {
        case .medium: value = 500
        case .semibold, .bold, .heavy, .black: value = 600
        default: value = 400
        }
        return Fonts.font(.inter, size: size, axes: [Fonts.opsz: min(max(size, 14), 32), Fonts.wght: value])
    }

    /// Inter with figures of one width, for counts and times.
    static func figures(_ size: CGFloat, medium: Bool = false) -> Font {
        sans(size, medium ? .medium : .regular).monospacedDigit()
    }

    // MARK: Motion

    /// One spring for things that move, one ease for things that fade.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let fade = Animation.easeOut(duration: 0.22)

    /// The bundled fonts (Resources/Fonts, SIL Open Font License), for this process.
    static func registerFonts() { Fonts.register() }
}

/// The bundled variable fonts, read from their files and set on their axes.
/// Registered once at launch; read from any view (a lock guards the tables).
enum Fonts {
    enum Face { case fraunces, frauncesItalic, inter }

    static let opsz = 0x6F70_737A, wght = 0x7767_6874, soft = 0x534F_4654, wonk = 0x574F_4E4B

    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [Face: CTFontDescriptor] = [:]
    nonisolated(unsafe) private static var cache: [String: Font] = [:]

    static func register() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return }
        let files: [(Face, String)] = [(.fraunces, "Fraunces.ttf"), (.frauncesItalic, "Fraunces-Italic.ttf"), (.inter, "Inter.ttf")]
        lock.lock()
        defer { lock.unlock() }
        for (face, name) in files {
            let url = folder.appendingPathComponent(name) as CFURL
            CTFontManagerRegisterFontsForURL(url, .process, nil)
            if let found = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor], let first = found.first {
                descriptors[face] = first
            }
        }
        cache.removeAll()
    }

    /// The face at `size` with its axes set; the system's serif or sans when
    /// the fonts are not bundled (a `swift run` build).
    static func font(_ face: Face, size: CGFloat, axes: [Int: CGFloat]) -> Font {
        let key = "\(face)-\(size)-\(axes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
        lock.lock()
        defer { lock.unlock() }
        if let font = cache[key] { return font }
        let font: Font
        if let base = descriptors[face] {
            var descriptor = base
            for (axis, value) in axes {
                descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, NSNumber(value: axis), value)
            }
            font = Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
        } else {
            let weight = axes[wght].map { $0 >= 550 ? Font.Weight.semibold : $0 >= 450 ? .medium : .regular } ?? .regular
            let system = Font.system(size: size, weight: weight, design: face == .inter ? .default : .serif)
            font = face == .frauncesItalic ? system.italic() : system
        }
        cache[key] = font
        return font
    }
}

/// Small, upper case, tracked: the label above a section, a count, a time.
struct Caption: View {
    let text: String
    var color: Color = Theme.ink4
    var size: CGFloat = 10.5

    init(_ text: String, color: Color = Theme.ink4, size: CGFloat = 10.5) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.sans(size, .medium).monospacedDigit())
            .tracking(size * 0.08)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A serif headline with an italic close: "Twelve things, *kept today.*"
func headline(_ lead: String, _ close: String, size: CGFloat, closeColor: Color? = nil) -> Text {
    let italic = Text(close).font(Theme.serif(size, italic: true))
    return Text(lead + " ").font(Theme.serif(size)) + (closeColor.map { italic.foregroundColor($0) } ?? italic)
}

/// A key as a cap: white, with a hairline and a one-point floor.  Pressed,
/// it sinks onto its floor.
struct KeyCap: View {
    let label: String
    var pressed = false

    init(_ label: String, pressed: Bool = false) {
        self.label = label
        self.pressed = pressed
    }

    var body: some View {
        Text(label)
            .font(Theme.sans(11))
            .foregroundStyle(Theme.ink2)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, label.count > 1 ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pressed ? Theme.well : Theme.raised)
                    .shadow(color: Theme.shadow.opacity(pressed ? 0 : 0.1), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
            .offset(y: pressed ? 1 : 0)
            .animation(Theme.snappy, value: pressed)
    }
}

extension Color {
    /// A color with a light and a dark value (0xRRGGBB).
    init(light: UInt32, dark: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Date {
    /// "Just now", "12 min ago", "20:09", "Yesterday", "Mon 13 Oct".
    var shortRelative: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if calendar.component(.year, from: self) != calendar.component(.year, from: Date()) {
            return formatted(.dateTime.day().month(.abbreviated).year())
        }
        return formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// Where the window can be dragged (and double-clicked to zoom) although
/// the content runs under its hidden title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
