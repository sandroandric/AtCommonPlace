import AppKit
import CommonPlaceKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The collage's materials, drawn on this Mac: film grain, the horizon,
/// saturated paper with pencil marks, and dry-brush ink.  Each texture is
/// made once and kept.
@MainActor
enum Textures {
    /// Specks of ink with transparent gaps, 256 px, tiled.
    static let darkGrain = grain(seed: 0x9E37_79B9, red: 26, green: 25, blue: 21, density: 0.36)
    /// Specks of light, for the dark stage and the horizon.
    static let lightGrain = grain(seed: 0x85EB_CA6B, red: 255, green: 250, blue: 240, density: 0.40)
    /// Dry-brush ink on nothing (laid on oat paper by `PaperPanel`).
    static let dryBrush: CGImage? = makeDryBrush(width: 720, height: 280)

    private static func grain(seed: UInt64, red: UInt8, green: UInt8, blue: UInt8, density: Double) -> CGImage {
        let size = 256
        var state = seed
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for index in 0..<(size * size) {
            // SplitMix64: the same grain on every launch.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let value = Double(z % 10_000) / 10_000
            let alpha = value > 1 - density ? (value - (1 - density)) / density : 0
            let a = UInt8(alpha * 255)
            pixels[index * 4] = UInt8(Int(red) * Int(a) / 255)
            pixels[index * 4 + 1] = UInt8(Int(green) * Int(a) / 255)
            pixels[index * 4 + 2] = UInt8(Int(blue) * Int(a) / 255)
            pixels[index * 4 + 3] = a
        }
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// Stretched noise, thresholded twice: solid cores, and edges broken by
    /// a fine speckle, like a dry brush dragged across rough paper.
    private static func makeDryBrush(width: Int, height: Int) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let base = CIFilter.randomGenerator().outputImage!
        let long = base.transformed(by: CGAffineTransform(scaleX: 110, y: 9)).applyingGaussianBlur(sigma: 3.5)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0)])
        let short = base.transformed(by: CGAffineTransform(translationX: 300, y: 70))
            .transformed(by: CGAffineTransform(scaleX: 30, y: 3)).applyingGaussianBlur(sigma: 1.2)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.4, y: 0, z: 0, w: 0)])
        let field = long.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: short]).cropped(to: rect)
        let edges = threshold(field, slope: 14, at: 0.5)
        let core = threshold(field, slope: 20, at: 0.6)
        let speckle = threshold(base.transformed(by: CGAffineTransform(translationX: 13, y: 7)).cropped(to: rect), slope: -8, at: 0.8)
        let dry = edges.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: speckle])
        let ink = core.composited(over: dry)
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]).createCGImage(ink, from: rect)
    }

    /// Ink wherever the red channel passes `at` (a steep ramp, `slope`).
    private static func threshold(_ image: CIImage, slope: CGFloat, at: CGFloat) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: slope, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0.086, y: 0.075, z: 0.06, w: -slope * at)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = matrix.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage!
    }
}

/// Film grain over whatever is beneath.
struct Grain: View {
    enum Tone { case dark, light }
    var tone: Tone = .dark
    var opacity: Double = 0.28

    var body: some View {
        Image(decorative: tone == .dark ? Textures.darkGrain : Textures.lightGrain, scale: 2)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(tone == .dark ? .multiply : .overlay)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The window's light.  By day a low warm sun from the upper right and a
/// cool fill from the lower left, with ink grain; by night an ember glow,
/// a faint blue fill and light grain on a deep warm black.
struct AmbientLight: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.ground
            if scheme == .dark {
                RadialGradient(colors: [Color(hex: 0xE3835C).opacity(0.13), .clear], center: UnitPoint(x: 0.88, y: -0.1),
                               startRadius: 0, endRadius: 620)
                RadialGradient(colors: [Color(hex: 0x788CBE).opacity(0.09), .clear], center: UnitPoint(x: 0, y: 1.1),
                               startRadius: 0, endRadius: 560)
                Grain(tone: .light, opacity: 0.2)
            } else {
                RadialGradient(colors: [Color(hex: 0xFFCEA0).opacity(0.42), .clear], center: UnitPoint(x: 0.86, y: -0.08),
                               startRadius: 0, endRadius: 640)
                RadialGradient(colors: [Color(hex: 0xCED6E8).opacity(0.38), .clear], center: UnitPoint(x: 0.04, y: 1.08),
                               startRadius: 0, endRadius: 560)
                Grain(opacity: 0.22)
            }
        }
        .ignoresSafeArea()
    }
}

/// The sky at this hour, grained: night blue to a burnt horizon to near black.
struct Horizon: View {
    let phase: SkyPhase

    var body: some View {
        ZStack {
            LinearGradient(stops: Self.stops(phase), startPoint: .top, endPoint: .bottom)
            if phase == .night { Stars() }
            Grain(tone: .light, opacity: 0.42)
        }
    }

    /// Words on this sky: ivory on the dark ones, ink on the bright ones.
    static func text(_ phase: SkyPhase) -> Color {
        phase == .day || phase == .morning ? Color(hex: 0x1A1915) : Theme.ivory
    }

    static func stops(_ phase: SkyPhase) -> [Gradient.Stop] {
        func s(_ hex: UInt32, _ at: Double) -> Gradient.Stop { .init(color: Color(hex: hex), location: at) }
        switch phase {
        case .night:
            return [s(0x05070D, 0), s(0x0B1222, 0.35), s(0x18213A, 0.6), s(0x2A2C45, 0.68), s(0x3B2A33, 0.71),
                    s(0x120F14, 0.76), s(0x0A0909, 1)]
        case .dawn:
            return [s(0x1B2440, 0), s(0x46598C, 0.25), s(0xA08DB0, 0.48), s(0xE8B2A0, 0.6), s(0xF5C78A, 0.67),
                    s(0xE99A5C, 0.705), s(0x5A3A2C, 0.75), s(0x1E1714, 0.82), s(0x121010, 1)]
        case .morning:
            return [s(0x5C86C4, 0), s(0x8EB0DD, 0.3), s(0xC7D9EC, 0.52), s(0xF1E6D2, 0.64), s(0xF2C99A, 0.69),
                    s(0xB98863, 0.73), s(0x4A3A2E, 0.78), s(0x1E1915, 1)]
        case .day:
            return [s(0x3E73C2, 0), s(0x6E9BD8, 0.3), s(0xA9C6E8, 0.52), s(0xE3ECF2, 0.64), s(0xF0E3C8, 0.69),
                    s(0xA7957A, 0.73), s(0x3F382E, 0.78), s(0x1A1714, 1)]
        case .golden:
            return [s(0x2B3F6E, 0), s(0x5D7BB5, 0.25), s(0xA9B6D3, 0.45), s(0xE9C9A6, 0.58), s(0xF2A65E, 0.66),
                    s(0xE5702E, 0.70), s(0x6E3218, 0.74), s(0x24140F, 0.82), s(0x140E0C, 1)]
        case .dusk:
            return [s(0x0B1222, 0), s(0x1C2D52, 0.2), s(0x4B68A3, 0.4), s(0x8D9BC4, 0.55), s(0xC9A6A0, 0.63),
                    s(0xE8925C, 0.685), s(0xE0561F, 0.71), s(0x5A2414, 0.74), s(0x1E1210, 0.8), s(0x120D0C, 1)]
        }
    }
}

/// A few stars, at night only, in the upper sky; always the same ones.
private struct Stars: View {
    var body: some View {
        Canvas { context, size in
            var state: UInt64 = 0x2545_F491
            for _ in 0..<38 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let x = Double(state >> 40 & 0xFFFF) / 65_535 * size.width
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let y = Double(state >> 40 & 0xFFFF) / 65_535 * size.height * 0.55
                let r = 0.4 + Double(state >> 20 & 0xFF) / 255 * 0.8
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(0.35 + Double(state >> 12 & 0xFF) / 255 * 0.5)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Saturated yellow paper with pencil marks (a scale, a line, an arrow, a
/// cross); with `brush`, its lower part is oat paper dragged with dry ink.
struct PaperPanel: View {
    var brush = true
    /// Two ⌘ keys drawn in ink, pressed (the capture board).
    var keys = false
    var keysPressed = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Theme.yellow
                Grain(opacity: 0.55).colorMultiply(Color(hex: 0xB9861E))
                if brush {
                    let top = size.height * 0.6
                    let edge = Path { path in
                        path.move(to: CGPoint(x: 0, y: top + 14))
                        path.addCurve(to: CGPoint(x: size.width, y: top - 6),
                                      control1: CGPoint(x: size.width * 0.3, y: top + 6),
                                      control2: CGPoint(x: size.width * 0.6, y: top + 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.addLine(to: CGPoint(x: 0, y: size.height))
                        path.closeSubpath()
                    }
                    ZStack {
                        Theme.oat
                        if let ink = Textures.dryBrush {
                            Image(decorative: ink, scale: 2).resizable().scaledToFill()
                        }
                        Grain(opacity: 0.3)
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(edge)
                }
                PencilMarks(stop: brush ? 0.52 : 0.4)
                if keys { DrawnKeys(pressed: keysPressed).frame(width: size.width, height: size.height) }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Pencil on the paper: thin, a little uneven, the colour of graphite on yellow.
private struct PencilMarks: View {
    /// How far down the long marks run (a share of the height).
    let stop: CGFloat

    var body: some View {
        Canvas { context, size in
            let h = size.height, w = size.width
            var path = Path()
            path.move(to: CGPoint(x: 28, y: 10))
            path.addLine(to: CGPoint(x: 28.6, y: h * stop))
            var y: CGFloat = 18
            var long = false
            while y < h * stop {
                path.move(to: CGPoint(x: long ? 22 : 24, y: y))
                path.addLine(to: CGPoint(x: long ? 36 : 33, y: y + 0.4))
                long.toggle()
                y += 12
            }
            path.move(to: CGPoint(x: w * 0.62, y: 0))
            path.addLine(to: CGPoint(x: w * 0.62 - 0.8, y: h * min(stop + 0.06, 0.44)))
            path.move(to: CGPoint(x: 48, y: h * 0.38))
            path.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.37), control1: CGPoint(x: 80, y: h * 0.37),
                          control2: CGPoint(x: 110, y: h * 0.385))
            path.move(to: CGPoint(x: w * 0.5 - 4, y: h * 0.37 - 6))
            path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.37))
            path.addLine(to: CGPoint(x: w * 0.5 - 4, y: h * 0.37 + 6))
            path.move(to: CGPoint(x: w * 0.82, y: 22))
            path.addLine(to: CGPoint(x: w * 0.82, y: 36))
            path.move(to: CGPoint(x: w * 0.82 - 7, y: 29))
            path.addLine(to: CGPoint(x: w * 0.82 + 7, y: 29))
            path.move(to: CGPoint(x: w * 0.82 + 10, y: 46))
            path.addLine(to: CGPoint(x: w * 0.82 + 16, y: 55))
            context.stroke(path, with: .color(Theme.pencil.opacity(0.85)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

/// Two ⌘ keys in ink on the paper, with the marks of being pressed.
private struct DrawnKeys: View {
    let pressed: Bool

    var body: some View {
        GeometryReader { geometry in
            let x = geometry.size.width / 2 - 76, y = geometry.size.height * 0.6
            ZStack(alignment: .topLeading) {
                ForEach(0..<2) { index in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.ink, lineWidth: 2)
                        .frame(width: 68, height: 60)
                        .overlay(Text("⌘").font(Theme.sans(26)).foregroundStyle(Theme.ink))
                        .offset(x: x + CGFloat(index) * 84, y: y + (pressed ? 3 : 0))
                }
                Path { path in
                    path.move(to: CGPoint(x: x + 60, y: y - 10)); path.addLine(to: CGPoint(x: x + 57, y: y - 19))
                    path.move(to: CGPoint(x: x + 76, y: y - 13)); path.addLine(to: CGPoint(x: x + 76, y: y - 23))
                    path.move(to: CGPoint(x: x + 92, y: y - 10)); path.addLine(to: CGPoint(x: x + 95, y: y - 19))
                }
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .opacity(pressed ? 1 : 0.35)
            }
            .animation(Theme.snappy, value: pressed)
        }
    }
}

/// The hand-made art (Resources/Art: gouache, dry brush, pencil), rendered
/// from its sources by scripts/render-art.sh and loaded once.
@MainActor
enum Art {
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Art/\(name).png"),
              let image = NSImage(contentsOf: url) else { return nil }
        // Rendered at 2x: its size in points is half its pixels.
        if let rep = image.representations.first {
            image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        }
        images[name] = image
        return image
    }
}

/// A piece of the art at a width, keeping its shape; nothing when it is missing.
struct ArtPiece: View {
    let name: String
    var width: CGFloat

    var body: some View {
        if let image = Art.image(name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
                .accessibilityHidden(true)
        }
    }
}

/// CommonPlace's mark, as drawn by hand: brushed corners and a gouache sun
/// setting on a dry horizon.  Ink on light, ivory on dark.  A click makes it
/// nod (a small press and a tilt, then it settles).
struct BrandMark: View {
    var size: CGFloat = 22
    /// Ivory whatever the appearance (on the stage and the horizon).
    var onDark = false
    var nodding = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let name = onDark || scheme == .dark ? "mark-ivory" : "mark-ink"
        Group {
            if let image = Art.image(name) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                HorizonMark(size: size, color: onDark ? Theme.ivory : Theme.ink)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(nodding ? 0.86 : 1)
        .rotationEffect(.degrees(nodding ? -6 : 0))
        .accessibilityHidden(true)
    }
}

/// The mark drawn as vectors: the menu bar's template image, and a stand-in
/// when the art is not bundled (a `swift run` build).
struct HorizonMark: View {
    var size: CGFloat = 20
    var color: Color = Theme.ink
    var sun: Color = Theme.accent
    /// 0 is at rest; 1 draws the corners in and lifts the sun (the moment of keeping).
    var closing: CGFloat = 0

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 100
            context.stroke(Self.corners(scale: s, inset: closing * 6),
                           with: .color(color), style: StrokeStyle(lineWidth: 7 * s, lineCap: .round, lineJoin: .round))
            context.fill(Self.sun(scale: s, rise: closing * 8), with: .color(sun))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The four corners in a 100-unit square, `inset` units in from their rest.
    static func corners(scale s: CGFloat, inset: CGFloat = 0) -> Path {
        let lo = (16 + inset) * s, hi = (84 - inset) * s, arm = 20 * s, r = 4 * s
        var path = Path()
        path.move(to: CGPoint(x: lo, y: lo + arm)); path.addLine(to: CGPoint(x: lo, y: lo + r))
        path.addQuadCurve(to: CGPoint(x: lo + r, y: lo), control: CGPoint(x: lo, y: lo)); path.addLine(to: CGPoint(x: lo + arm, y: lo))
        path.move(to: CGPoint(x: hi - arm, y: lo)); path.addLine(to: CGPoint(x: hi - r, y: lo))
        path.addQuadCurve(to: CGPoint(x: hi, y: lo + r), control: CGPoint(x: hi, y: lo)); path.addLine(to: CGPoint(x: hi, y: lo + arm))
        path.move(to: CGPoint(x: hi, y: hi - arm)); path.addLine(to: CGPoint(x: hi, y: hi - r))
        path.addQuadCurve(to: CGPoint(x: hi - r, y: hi), control: CGPoint(x: hi, y: hi)); path.addLine(to: CGPoint(x: hi - arm, y: hi))
        path.move(to: CGPoint(x: lo + arm, y: hi)); path.addLine(to: CGPoint(x: lo + r, y: hi))
        path.addQuadCurve(to: CGPoint(x: lo, y: hi - r), control: CGPoint(x: lo, y: hi)); path.addLine(to: CGPoint(x: lo, y: hi - arm))
        return path
    }

    /// The sun: a half disc of radius 18 on the horizon at 62, `rise` units up.
    static func sun(scale s: CGFloat, rise: CGFloat = 0) -> Path {
        var path = Path()
        let center = CGPoint(x: 50 * s, y: (62 - rise) * s)
        path.move(to: CGPoint(x: 32 * s, y: center.y))
        path.addArc(center: center, radius: 18 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// The menu bar's template image (drawn in black; macOS tints it).
    @MainActor
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / 100
            context.addPath(corners(scale: s).cgPath)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(9 * s)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            context.addPath(sun(scale: s).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A rectangle whose right edge is torn by hand: small, uneven teeth,
/// always the same ones.
struct TornEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        var state: UInt64 = 0x51F1_5EED
        var y = rect.minY
        path.addLine(to: CGPoint(x: rect.maxX - 3, y: y))
        while y < rect.maxY {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let step = 3 + CGFloat(state >> 59)              // 3 to 18 pt
            let depth = CGFloat(state >> 40 & 0xFF) / 255 * 5  // 0 to 5 pt in
            y = min(rect.maxY, y + step)
            path.addLine(to: CGPoint(x: rect.maxX - depth, y: y))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
