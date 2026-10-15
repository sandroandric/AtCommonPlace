import Foundation

/// Files a capture by its meaning vector (title and topics, EmbeddingGemma 2).
///
/// A capture joins the collection whose centre it is closest to, when that
/// is close enough (`joinThreshold`) and one member is as close as a pair
/// that would form a collection (`formThreshold`): a centre alone drifts
/// towards "like everything" as a collection grows, and pulled 14 of 16
/// unrelated pages into one before this check.  Otherwise it looks for unsorted
/// captures like it (`formThreshold`): with at least one, they start a new
/// collection together.  Alone, it stays unsorted until a similar capture
/// arrives, so the library never fills with one-item collections.
public struct Organizer: Sendable {
    public enum Decision: Equatable, Sendable {
        case join(collectionID: String, similarity: Float)
        /// Start a collection with these unsorted captures (and this one).
        case form(with: [String], similarity: Float)
        case stayUnsorted
    }

    public var joinThreshold: Float
    public var formThreshold: Float
    /// At most this many unsorted captures join a new collection at once.
    public var maxFormMembers: Int

    public init(joinThreshold: Float = Organizer.defaultJoin, formThreshold: Float = Organizer.defaultForm, maxFormMembers: Int = 12) {
        self.joinThreshold = joinThreshold
        self.formThreshold = formThreshold
        self.maxFormMembers = maxFormMembers
    }

    /// Measured with cp-eval on 16 real captures' meaning vectors:
    /// same-topic pairs 0.795–0.879, different topics a median of 0.695 and
    /// at most 0.792.
    public static let defaultJoin: Float = 0.80
    public static let defaultForm: Float = 0.79

    /// A collection as the organizer sees it: its members' vectors.
    public struct Group: Sendable {
        public var id: String
        public var members: [[Float]]
        public init(id: String, members: [[Float]]) {
            self.id = id
            self.members = members
        }
    }

    /// Where `vector` goes: `collections` with their members' vectors,
    /// `unsorted` the vectors of captures in no collection (not this one).
    public func decide(vector: [Float], collections: [Group], unsorted: [(id: String, vector: [Float])]) -> Decision {
        let candidates = collections.compactMap { group -> (String, Float)? in
            guard let centroid = VectorMath.centroid(group.members) else { return nil }
            let nearestMember = group.members.map { VectorMath.dot(vector, $0) }.max() ?? 0
            let toCentre = VectorMath.dot(vector, centroid)
            return toCentre >= joinThreshold && nearestMember >= formThreshold ? (group.id, toCentre) : nil
        }
        if let best = candidates.max(by: { $0.1 < $1.1 }) {
            return .join(collectionID: best.0, similarity: best.1)
        }
        let near = unsorted
            .map { ($0.id, VectorMath.dot(vector, $0.vector)) }
            .filter { $0.1 >= formThreshold }
            .sorted { $0.1 > $1.1 }
            .prefix(maxFormMembers)
        if let top = near.first {
            return .form(with: near.map(\.0), similarity: top.1)
        }
        return .stayUnsorted
    }

    /// The collection is named again as it doubles (2, 4, 8, … members),
    /// unless the user named it.
    public static func shouldRename(_ collection: CaptureCollection) -> Bool {
        !collection.userNamed && collection.count >= max(2, collection.namedAtCount * 2)
    }
}

/// Names a collection from its members: a short name and an emoji, by the
/// same local model that describes captures.
public struct CollectionNamer: Sendable {
    public let client: OllamaClient
    public let model: String

    public init(client: OllamaClient, model: String) {
        self.client = client
        self.model = model
    }

    public static func prompt(_ members: [Capture]) -> String {
        let lines = members.prefix(12).map { capture -> String in
            let tags = capture.tags.isEmpty ? "" : " [\(capture.tags.joined(separator: ", "))]"
            return "- \(capture.displayTitle): \(capture.summary ?? "")\(tags)"
        }
        return """
            These items were saved together in a personal library:
            \(lines.joined(separator: "\n"))

            Name the collection they form. Answer with JSON only:
            {"name": "2 to 4 words, title case, specific (not 'Miscellaneous' or 'Screenshots')",
             "emoji": "one emoji that fits"}
            """
    }

    public func name(_ members: [Capture]) async throws -> (name: String, emoji: String) {
        let answer = try await client.generate(model: model, prompt: Self.prompt(members), maxTokens: 80, timeout: 120)
        return Self.parse(answer)
    }

    /// The name and emoji, checked: at most 40 characters, one emoji (📁
    /// when the model gave none).
    public static func parse(_ answer: String) -> (name: String, emoji: String) {
        let object = Describer.jsonObject(in: answer) ?? [:]
        let name = Describer.clean(object["name"] as? String, max: 40) ?? "Untitled collection"
        let emoji = (object["emoji"] as? String).flatMap { $0.first(where: isEmoji) }.map(String.init) ?? "📁"
        return (name, emoji)
    }

    /// An emoji character: one shown as an emoji by default, one asking for
    /// emoji presentation (U+FE0F), or a flag (two regional indicators, which
    /// are not "emoji presentation" on their own: 🇯🇵 fell back to 📁).
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        if scalars.contains(where: { $0.value == 0xFE0F }) { return true }
        return scalars.count == 2 && scalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
    }
}
