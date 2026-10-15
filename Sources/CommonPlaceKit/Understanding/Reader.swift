import Foundation
import ImageIO
import Vision

/// Reads the text on a capture with Apple's on-device text recognition:
/// lines top to bottom, in the recognition's own order.
public enum Reader {
    public static func text(in imageData: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}

/// The models CommonPlace uses, and the Ollama they need.
public enum Models {
    /// Image and text in one space: what a capture is, and what a search means.
    public static let embedding = "embeddinggemma-2:440m"
    public static let embeddingDimension = 768
    /// EmbeddingGemma 2 runs from this Ollama.
    public static let minimumOllama = "0.40.0"

    /// The vision model for this Mac: Google's Gemma 4, quantization-aware
    /// builds.  E4B from 24 GB (the best titles; about 6.6 GB while it
    /// reads), E2B below (as accurate in cp-eval, about 4.4 GB).
    public static func vision(ramGB: Int = Int(ProcessInfo.processInfo.physicalMemory >> 30)) -> String {
        ramGB >= 24 ? "gemma4:e4b-it-qat" : "gemma4:e2b-it-qat"
    }

    /// The download sizes setup shows.
    public static let sizes: [String: String] = [
        "embeddinggemma-2:440m": "710 MB",
        "gemma4:e4b-it-qat": "6.2 GB",
        "gemma4:e2b-it-qat": "4.3 GB",
    ]

    /// Whether Ollama `version` is at least `minimum` (numeric parts, a
    /// pre-release suffix ignored).
    public static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(version), b = parts(minimum)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }
}

/// The text EmbeddingGemma 2 is given with a capture's image, and with a query.
public enum EmbeddingText {
    /// "title: <title> | text: <summary, tags, the start of the screen's text>".
    public static func document(_ capture: Capture) -> String {
        let title = [capture.app, capture.displayTitle].filter { !$0.isEmpty }.joined(separator: " — ")
        var parts: [String] = []
        if let summary = capture.summary, !summary.isEmpty { parts.append(summary) }
        if !capture.tags.isEmpty { parts.append(capture.tags.joined(separator: ", ")) }
        if let note = capture.note, !note.isEmpty { parts.append(note) }
        if let transcript = capture.transcript, !transcript.isEmpty { parts.append(String(transcript.prefix(1_200))) }
        if let ocr = capture.ocrText, !ocr.isEmpty { parts.append(String(ocr.prefix(1_200))) }
        return "title: \(title.isEmpty ? "none" : title) | text: \(parts.joined(separator: "\n"))"
    }

    /// "title: none | text: <title>. Topics: <tags>. <note>": what it is
    /// about, without the page's look or boilerplate.
    public static func meaning(_ capture: Capture) -> String {
        var text = capture.displayTitle
        if !capture.tags.isEmpty { text += ". Topics: " + capture.tags.joined(separator: ", ") }
        if let note = capture.note, !note.isEmpty { text += ". " + note }
        return "title: none | text: \(text)"
    }

    public static func query(_ text: String) -> String {
        "task: search result | query: \(text)"
    }
}
