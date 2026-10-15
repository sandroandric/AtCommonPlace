import Foundation

/// What the vision model says a capture is.
public struct CaptureDescription: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var kind: CaptureKind
    public var tags: [String]
    /// Short passages worth keeping, copied from the screen.
    public var highlights: [String]
    /// Links that appear on the screen (or the page's own URL).
    public var links: [String]

    public init(title: String, summary: String, kind: CaptureKind, tags: [String], highlights: [String], links: [String]) {
        self.title = title
        self.summary = summary
        self.kind = kind
        self.tags = tags
        self.highlights = highlights
        self.links = links
    }
}

/// Asks a small local vision model to describe a capture, and checks what
/// it answers: a title, a summary, a kind, tags, highlights copied from the
/// screen, and links.  Nothing is taken on trust: lengths are capped, tags
/// cleaned, and a link is kept only when it appears in the screen's text
/// or is the page's own URL (a model can invent a plausible URL).
public struct Describer: Sendable {
    public static let system = """
        You file screenshots, photos and videos into a person's personal library (a commonplace book). \
        You look at one image and answer with JSON only. Describe what it shows, not an app's chrome. \
        Never invent facts, names or links that are not visible or said.
        """

    public let client: OllamaClient
    public let model: String

    public init(client: OllamaClient, model: String) {
        self.client = client
        self.model = model
    }

    /// What the model is told it is looking at, per kind of capture.
    public struct Context: Sendable {
        public var media: CaptureMedia = .screen
        public var app: String
        public var windowTitle: String
        public var url: String?
        public var duration: Double?
        public var takenAt: Date?
        public var transcript: String?

        public init(media: CaptureMedia = .screen, app: String, windowTitle: String, url: String? = nil,
                    duration: Double? = nil, takenAt: Date? = nil, transcript: String? = nil) {
            self.media = media
            self.app = app
            self.windowTitle = windowTitle
            self.url = url
            self.duration = duration
            self.takenAt = takenAt
            self.transcript = transcript
        }

        public init(_ capture: Capture) {
            self.init(media: capture.media, app: capture.app, windowTitle: capture.windowTitle, url: capture.url,
                      duration: capture.duration, takenAt: capture.takenAt, transcript: capture.transcript)
        }
    }

    public static func prompt(app: String, windowTitle: String, url: String?, ocrExcerpt: String) -> String {
        prompt(Context(app: app, windowTitle: windowTitle, url: url), ocrExcerpt: ocrExcerpt)
    }

    public static func prompt(_ context: Context, ocrExcerpt: String) -> String {
        let kinds = CaptureKind.allCases.map(\.rawValue).joined(separator: ", ")
        let taken = context.takenAt.map { " Taken \($0.formatted(date: .long, time: .shortened))." } ?? ""
        let header: String
        switch context.media {
        case .screen:
            header = """
                App: \(context.app)
                Window: \(context.windowTitle.isEmpty ? "(untitled)" : context.windowTitle)
                \(context.url.map { "URL: \($0)\n" } ?? "")Text read from the screen (may be partial):
                """
        case .photo:
            header = """
                This is a photo (file "\(context.windowTitle)").\(taken) Describe what it shows: the subject, the place, \
                the moment, any text in it.
                Text read from the photo (may be empty):
                """
        case .video:
            let length = context.duration.map { " \(Int($0.rounded())) seconds long" } ?? ""
            let said = context.transcript.map { "\nWhat is said in it:\n\"\"\"\n\(excerpt($0))\n\"\"\"" } ?? ""
            header = """
                This is a video (file "\(context.windowTitle)")\(length).\(taken) The image shows key frames in order, \
                left to right, top to bottom. Describe what happens in it.\(said)
                Text read from the frames (may be empty):
                """
        }
        return """
            \(header)
            \"\"\"
            \(ocrExcerpt)
            \"\"\"

            Answer with this JSON object:
            {"title": "the subject itself in 2 to 7 words, like a good bookmark (e.g. 'Espresso', 'Refunding Stripe payments'); not the site or app name",
             "summary": "one or two sentences about the content itself; never start with 'A screenshot' or 'A page'",
             "kind": "one of: \(kinds)",
             "tags": ["2 to 5 short lowercase topic tags about the subject (not the website, app or 'screenshot')"],
             "highlights": ["up to 3 short passages copied exactly from the screen that are worth remembering"],
             "links": ["URLs visible on the screen, if any"]}
            """
    }

    /// Describe the capture (its picture, metadata and OCR text).
    public func describe(image: Data, app: String, windowTitle: String, url: String?, ocrText: String) async throws -> CaptureDescription {
        try await describe(image: image, context: Context(app: app, windowTitle: windowTitle, url: url), ocrText: ocrText)
    }

    /// A photo's or video's highlights may also quote what is said.
    public func describe(image: Data, context: Context, ocrText: String) async throws -> CaptureDescription {
        let answer = try await client.generate(
            model: model,
            prompt: Self.prompt(context, ocrExcerpt: Self.excerpt(ocrText)),
            system: Self.system,
            images: [image]
        )
        let checkable = [ocrText, context.transcript ?? ""].joined(separator: "\n")
        let fallback = context.windowTitle.isEmpty ? context.app : context.windowTitle
        return try Self.parse(answer, ocrText: checkable, url: context.url, fallbackTitle: fallback)
    }

    public enum ParseError: Error, Equatable {
        case notJSON(String)
    }

    /// The model's JSON, checked.  A missing title or summary falls back to
    /// the window's title and nothing; tags are lowercased, de-duplicated and
    /// capped at 5; highlights must appear in the OCR text.
    public static func parse(_ answer: String, ocrText: String, url: String?, fallbackTitle: String) throws -> CaptureDescription {
        guard let object = jsonObject(in: answer) else { throw ParseError.notJSON(String(answer.prefix(200))) }
        let rawTitle = clean(object["title"] as? String, max: 90) ?? clean(fallbackTitle, max: 90) ?? "Untitled"
        let title = withoutSiteName(rawTitle, url: url)
        let summary = withoutPreamble(clean(object["summary"] as? String, max: 400) ?? "")
        let kind = CaptureKind.parse(object["kind"] as? String)

        var tags: [String] = []
        for raw in (object["tags"] as? [Any] ?? []).compactMap({ $0 as? String }) {
            let tag = LibraryStore.normalizedTag(raw)
            guard !tag.isEmpty, tag.count <= 32, !tags.contains(tag) else { continue }
            tags.append(tag)
            if tags.count == 5 { break }
        }

        let screen = squashed(ocrText)
        let highlights = (object["highlights"] as? [Any] ?? []).compactMap { $0 as? String }
            .compactMap { clean($0, max: 280) }
            .filter { screen.contains(squashed($0)) }
            .prefix(3)

        var links: [String] = []
        if let url, isWebLink(url) { links.append(url) }
        for raw in (object["links"] as? [Any] ?? []).compactMap({ $0 as? String }) {
            let link = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;)")))
            guard isWebLink(link) || isWebLink("https://\(link)") else { continue }
            let normalized = link.hasPrefix("http") ? link : "https://\(link)"
            let bare = squashed(link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
            guard screen.contains(bare), !links.contains(normalized) else { continue }
            links.append(normalized)
            if links.count == 6 { break }
        }

        return CaptureDescription(title: title, summary: summary, kind: kind, tags: tags,
                                  highlights: Array(highlights), links: links)
    }

    // MARK: - Helpers

    /// The OCR text the prompt carries: the first ~3,000 characters.
    static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 3_000 ? String(trimmed.prefix(3_000)) + "…" : (trimmed.isEmpty ? "(none)" : trimmed)
    }

    /// The first JSON object in `text` (models sometimes wrap it in prose or fences).
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let data = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The title without the site it came from at its end ("Matcha -
    /// Wikipedia", "Kyoto Wikipedia article", "Baguette Wikipedia"): the card
    /// shows the source already.  Measured: 5 of 20 titles kept it despite
    /// the prompt.  The site is the URL host's main label (en.wikipedia.org
    /// → wikipedia); a title that is only the site name is kept.
    static func withoutSiteName(_ title: String, url: String?) -> String {
        guard let host = url.flatMap({ URL(string: $0)?.host() }) else { return title }
        let labels = host.lowercased().split(separator: ".")
        guard labels.count >= 2 else { return title }
        let site = NSRegularExpression.escapedPattern(for: String(labels[labels.count - 2]))
        let pattern = #"(?i)\s*[-–—|:·]?\s*"# + site + #"(\s+(article|page|entry))?\s*$"#
        guard let range = title.range(of: pattern, options: .regularExpression), range.lowerBound > title.startIndex else {
            return title
        }
        let rest = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        // "… Wikipedia article" can leave "article" behind the subject: drop a dangling one.
        let trimmed = rest.replacingOccurrences(of: #"(?i)\s+(article|page)$"#, with: "", options: .regularExpression)
        // "Swift on GitHub": the site is part of the phrase, keep it.
        let lastWord = trimmed.split(separator: " ").last.map { $0.lowercased() } ?? ""
        let prepositions: Set<String> = ["on", "at", "from", "in", "via", "for", "of", "to", "by", "with"]
        return trimmed.isEmpty || prepositions.contains(lastWord) ? title : trimmed
    }

    /// The summary without the opening small models add whatever they are
    /// told ("A screenshot of the …", "This screenshot shows …"), capitalized.
    /// Measured: 4 of 16 summaries began that way despite the prompt.
    static func withoutPreamble(_ summary: String) -> String {
        let pattern = #"^(?i)(a |this |the )?(screenshot|screen ?shot|webpage|web page|page|image)( of| from| shows| displays| showing)?( the| a| an)?\s+"#
        guard let range = summary.range(of: pattern, options: .regularExpression),
              range.upperBound < summary.endIndex else { return summary }
        let rest = summary[range.upperBound...]
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    static func clean(_ text: String?, max: Int) -> String? {
        guard let text else { return nil }
        let single = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        guard !single.isEmpty else { return nil }
        return single.count > max ? String(single.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : single
    }

    /// Lowercased with every run of non-alphanumerics removed: OCR line
    /// breaks and spacing differ from what the model copies.
    static func squashed(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func isWebLink(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), host.contains(".") else { return false }
        return true
    }
}
