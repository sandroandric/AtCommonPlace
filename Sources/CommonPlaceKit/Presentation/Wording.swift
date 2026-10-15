import Foundation

/// The library's sentences: counts in words, the day's headline, the
/// search's headline and the moments worth marking.
public enum Wording {
    /// "Twelve things", "One thing", "143 things": spelled out below 100.
    public static func count(_ n: Int, _ singular: String, _ plural: String, capitalized: Bool = true) -> String {
        let number: String
        if n >= 0, n < 100 {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .spellOut
            let spelled = formatter.string(from: NSNumber(value: n)) ?? String(n)
            number = capitalized ? spelled.prefix(1).uppercased() + spelled.dropFirst() : spelled
        } else {
            number = n.formatted()
        }
        return "\(number) \(n == 1 ? singular : plural)"
    }

    /// The day's headline in two parts: the plain lead and the italic close.
    public static func today(kept n: Int, hour: Int) -> (lead: String, close: String) {
        if n == 0 { return hour >= 18 ? ("A quiet day,", "nothing kept.") : ("Nothing kept", "yet today.") }
        return (count(n, "thing", "things") + ",", "kept today.")
    }

    /// The search's headline: lead, then the query in italics.
    public static func search(found n: Int) -> String {
        n == 0 ? "Nothing yet about" : count(n, "thing", "things") + " about"
    }

    /// Counts worth a word when a capture is kept: the first, the tenth,
    /// and every hundredth.
    public static func milestone(total: Int) -> String? {
        switch total {
        case 1: return "Your first thing kept."
        case 10: return "Ten things kept."
        case let n where n > 0 && n % 100 == 0: return count(n, "thing", "things") + " kept."
        default: return nil
        }
    }
}

/// The sky at a time of day, for the horizon in the library's header.
public enum SkyPhase: String, CaseIterable, Sendable {
    case night, dawn, morning, day, golden, dusk

    public static func at(hour: Int, minute: Int = 0) -> SkyPhase {
        let t = Double(hour) + Double(minute) / 60
        switch t {
        case 5..<7: return .dawn
        case 7..<10: return .morning
        case 10..<17: return .day
        case 17..<19: return .golden
        case 19..<21: return .dusk
        default: return .night
        }
    }
}

/// A video's contact sheet (`MediaImporter.contactSheet`) cut back into its frames.
public enum ContactSheet {
    /// The frames' rectangles in a sheet of `width` × `height` pixels (top-left
    /// origin), in order, for a sheet of `MediaImporter.sheetFrames` frames
    /// laid three across; nil when the sheet is not that shape.
    public static func cells(width: Int, height: Int, frames: Int = MediaImporter.sheetFrames) -> [CGRect]? {
        let columns = min(3, frames), gap = 8, cellWidth = 640
        let rows = Int((Double(frames) / Double(columns)).rounded(.up))
        guard width == columns * cellWidth + (columns - 1) * gap, rows > 0 else { return nil }
        let cellHeight = (height - (rows - 1) * gap) / rows
        guard cellHeight > 0, rows * cellHeight + (rows - 1) * gap == height else { return nil }
        return (0..<frames).map { index in
            CGRect(x: (index % columns) * (cellWidth + gap), y: (index / columns) * (cellHeight + gap),
                   width: cellWidth, height: cellHeight)
        }
    }
}
