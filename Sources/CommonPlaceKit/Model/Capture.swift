import Foundation

/// What a capture is, as the vision model classifies it.  The library's
/// Kinds shelf groups by it; `other` when nothing fits.
public enum CaptureKind: String, CaseIterable, Codable, Sendable {
    case article, code, design, chat, email, document, spreadsheet, slides
    case product, receipt, recipe, food, place, video, social, data, idea, other

    public var title: String {
        switch self {
        case .article: return "Articles"
        case .code: return "Code"
        case .design: return "Design"
        case .chat: return "Chats"
        case .email: return "Email"
        case .document: return "Documents"
        case .spreadsheet: return "Spreadsheets"
        case .slides: return "Slides"
        case .product: return "Products"
        case .receipt: return "Receipts"
        case .recipe: return "Recipes"
        case .food: return "Food & drink"
        case .place: return "Places"
        case .video: return "Video"
        case .social: return "Social"
        case .data: return "Charts & data"
        case .idea: return "Ideas"
        case .other: return "Other"
        }
    }

    /// SF Symbol for chips and the sidebar.
    public var symbol: String {
        switch self {
        case .article: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .design: return "paintpalette"
        case .chat: return "bubble.left.and.bubble.right"
        case .email: return "envelope"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .slides: return "rectangle.on.rectangle"
        case .product: return "bag"
        case .receipt: return "receipt"
        case .recipe: return "fork.knife"
        case .food: return "cup.and.saucer"
        case .place: return "mappin.and.ellipse"
        case .video: return "play.rectangle"
        case .social: return "person.2"
        case .data: return "chart.bar.xaxis"
        case .idea: return "lightbulb"
        case .other: return "square.dashed"
        }
    }

    /// Lenient: the model's word, case-insensitive, with a few synonyms.
    public static func parse(_ raw: String?) -> CaptureKind {
        let word = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let kind = CaptureKind(rawValue: word) { return kind }
        switch word {
        case "web page", "webpage", "blog", "news", "post": return .article
        case "terminal", "source code", "github": return .code
        case "message", "messages", "slack": return .chat
        case "pdf", "doc", "notes", "note": return .document
        case "chart", "dashboard", "graph", "table": return .data
        case "shopping", "listing": return .product
        case "drink", "meal", "dish", "pastry", "coffee", "food and drink": return .food
        case "invoice", "order": return .receipt
        case "map", "location": return .place
        case "tweet", "social media": return .social
        case "presentation": return .slides
        default: return .other
        }
    }
}

/// What was kept: a window, a photo, a video.
public enum CaptureMedia: String, CaseIterable, Codable, Sendable {
    case screen, photo, video

    public var title: String {
        switch self {
        case .screen: return "Screens"
        case .photo: return "Photos"
        case .video: return "Videos"
        }
    }

    public var symbol: String {
        switch self {
        case .screen: return "macwindow"
        case .photo: return "photo"
        case .video: return "film"
        }
    }
}

/// The two vectors a capture has, both from EmbeddingGemma 2.
public enum VectorSpace: String, CaseIterable, Sendable {
    /// The picture with its text: search by how it looked as well as by meaning.
    case look
    /// The title and topics alone: what it is about.  Collections and
    /// "related" use it, so pages that merely look alike (every Wikipedia
    /// article) do not gather.
    case meaning
}

/// Where a capture is in its understanding: each stage runs once, in order,
/// and a failed stage is retried later (Ollama asleep, a model missing).
public enum CaptureStage: String, Codable, Sendable {
    case captured      // image and metadata kept
    case read          // OCR done
    case described     // the vision model's title, summary, kind, tags
    case embedded      // EmbeddingGemma 2 vector stored
    case organized     // filed into a collection
}

public struct Capture: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var createdAt: Date
    public var app: String
    public var bundleID: String?
    public var windowTitle: String
    public var url: String?
    public var documentPath: String?
    public var width: Int
    public var height: Int
    public var stage: CaptureStage
    public var ocrText: String?
    public var title: String?
    public var summary: String?
    public var kind: CaptureKind?
    public var tags: [String]
    public var highlights: [String]
    public var links: [String]
    public var note: String?
    public var favorite: Bool
    public var collectionID: String?
    public var lastError: String?
    public var media: CaptureMedia
    /// A video's length in seconds.
    public var duration: Double?
    /// When a photo or video was taken (its metadata), not when it was kept.
    public var takenAt: Date?
    /// The picture the library shows, relative to the library root; nil is
    /// `captures/<id>.png` (a kept window).
    public var imageFile: String?
    /// An imported photo's or video's own file, copied into the library.
    public var originalFile: String?
    /// What is said in a video (on-device speech recognition).
    public var transcript: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        createdAt: Date = Date(),
        app: String,
        bundleID: String? = nil,
        windowTitle: String,
        url: String? = nil,
        documentPath: String? = nil,
        width: Int,
        height: Int,
        stage: CaptureStage = .captured,
        ocrText: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        kind: CaptureKind? = nil,
        tags: [String] = [],
        highlights: [String] = [],
        links: [String] = [],
        note: String? = nil,
        favorite: Bool = false,
        collectionID: String? = nil,
        lastError: String? = nil,
        media: CaptureMedia = .screen,
        duration: Double? = nil,
        takenAt: Date? = nil,
        imageFile: String? = nil,
        originalFile: String? = nil,
        transcript: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.app = app
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.documentPath = documentPath
        self.width = width
        self.height = height
        self.stage = stage
        self.ocrText = ocrText
        self.title = title
        self.summary = summary
        self.kind = kind
        self.tags = tags
        self.highlights = highlights
        self.links = links
        self.note = note
        self.favorite = favorite
        self.collectionID = collectionID
        self.lastError = lastError
        self.media = media
        self.duration = duration
        self.takenAt = takenAt
        self.imageFile = imageFile
        self.originalFile = originalFile
        self.transcript = transcript
    }

    /// The card's heading: the model's title, else the window's, else the app.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if !windowTitle.isEmpty { return windowTitle }
        return app
    }

    /// The source for the card's footer: the site's host, else the app
    /// ("Photos" and "Videos" for imports).
    public var sourceName: String {
        if let url, let host = URL(string: url)?.host() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return media == .screen ? app : media.title
    }
}

/// A collection the organizer formed (or the user made): similar captures
/// together, named by the vision model from its members.
public struct CaptureCollection: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var emoji: String
    public var createdAt: Date
    public var updatedAt: Date
    public var count: Int
    /// The member count when it was last named: it is named again as it grows.
    public var namedAtCount: Int
    /// Named (or renamed) by the user: the organizer never renames it.
    public var userNamed: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        emoji: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        count: Int = 0,
        namedAtCount: Int = 0,
        userNamed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.count = count
        self.namedAtCount = namedAtCount
        self.userNamed = userNamed
    }
}
