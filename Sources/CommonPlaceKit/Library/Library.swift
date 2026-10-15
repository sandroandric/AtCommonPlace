import Foundation

/// The library: keeps captures and understands them, one at a time, in the
/// background.  Each capture goes through its stages (read → described →
/// embedded → organized); a stage that fails (Ollama away, a model not
/// pulled) is retried later, the capture stays in the library meanwhile.
public actor Library {
    public let store: LibraryStore
    let client: OllamaClient
    private(set) var visionModel: String
    let embeddingModel: String
    var organizer: Organizer
    /// The run under way, which every caller of `work()` waits for.
    private var run: Task<Void, Never>?

    /// Called on the main actor when something in the library changed.
    public var onChange: (@MainActor @Sendable () -> Void)?

    public init(store: LibraryStore, client: OllamaClient = OllamaClient(),
                visionModel: String = Models.vision(), embeddingModel: String = Models.embedding,
                organizer: Organizer = Organizer()) {
        self.store = store
        self.client = client
        self.visionModel = visionModel
        self.embeddingModel = embeddingModel
        self.organizer = organizer
    }

    /// Describe and name with another vision model from now on.
    public func setVisionModel(_ model: String) {
        visionModel = model
    }

    public func setOnChange(_ handler: @escaping @MainActor @Sendable () -> Void) {
        onChange = handler
    }

    // MARK: - Keeping

    /// Keep a capture: its PNG and JPEG thumbnail are written, its row
    /// stored, and its understanding started.
    public func keep(_ capture: Capture, png: Data, thumbnail: Data) async throws {
        try png.write(to: store.imageURL(capture.id), options: .atomic)
        try thumbnail.write(to: store.thumbURL(capture.id), options: .atomic)
        try store.insert(capture)
        await changed()
        Task { await self.work() }
    }

    /// Keep an imported photo or video: its picture, thumbnail, a video's
    /// contact sheet and a copy of the original file go into the library.
    public func keepImported(_ imported: MediaImporter.Imported, original: URL) async throws {
        let capture = imported.capture
        try imported.image.write(to: store.imageURL(for: capture), options: .atomic)
        try imported.thumbnail.write(to: store.thumbURL(capture.id), options: .atomic)
        if let sheet = imported.sheet { try sheet.write(to: store.sheetURL(capture.id), options: .atomic) }
        if let copy = store.originalURL(for: capture) {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: original, to: copy)
        }
        try store.insert(capture)
        await changed()
        Task { await self.work() }
    }

    /// What the models look at: a video's contact sheet, else the picture.
    func modelImage(_ capture: Capture) throws -> Data {
        if capture.media == .video, let sheet = try? Data(contentsOf: store.sheetURL(capture.id)) { return sheet }
        return try Data(contentsOf: store.imageURL(for: capture))
    }

    // MARK: - Understanding

    /// Process every capture that is due, until none is, and return when
    /// that is done.  One run at a time: a call during a run waits for it,
    /// then starts another when something is still due (a capture kept as
    /// the run was finishing).
    public func work() async {
        if let run { await run.value }
        if let run {
            await run.value
            return
        }
        guard let due = try? store.pending(limit: 1), !due.isEmpty else { return }
        let task = Task { await self.drain() }
        run = task
        await task.value
    }

    private func drain() async {
        while let batch = try? store.pending(), !batch.isEmpty {
            for capture in batch {
                await advance(capture)
            }
        }
        run = nil
    }

    /// Run the capture's remaining stages; stop at the first failure.
    func advance(_ capture: Capture) async {
        var capture = capture
        do {
            if capture.stage == .captured {
                let text = try Reader.text(in: try modelImage(capture))
                var transcript: String?
                if capture.media == .video, let original = store.originalURL(for: capture) {
                    transcript = await Transcriber.transcribe(original)
                }
                try store.setRead(capture.id, ocrText: text, transcript: transcript)
                capture.ocrText = text
                capture.transcript = transcript
                capture.stage = .read
            }
            if capture.stage == .read {
                let description = try await Describer(client: client, model: visionModel).describe(
                    image: Self.downscaled(try modelImage(capture)), context: Describer.Context(capture),
                    ocrText: capture.ocrText ?? ""
                )
                try store.setDescribed(capture.id, description)
                capture = try store.capture(capture.id) ?? capture
                await changed()
            }
            if capture.stage == .described {
                let vectors = try await client.embed(model: embeddingModel, inputs: [
                    .init(text: EmbeddingText.document(capture), image: Self.downscaled(try modelImage(capture))),
                    .init(text: EmbeddingText.meaning(capture)),
                ])
                try store.setEmbedding(capture.id, model: embeddingModel,
                                       vectors: [.look: vectors[0], .meaning: vectors[1]])
                capture.stage = .embedded
            }
            if capture.stage == .embedded {
                try await organize(capture.id)
                await changed()
            }
        } catch {
            let (message, retry) = Self.retryPlan(for: error, attempt: capture)
            try? store.recordFailure(capture.id, error: message, retryAfter: retry)
            await changed()
        }
    }

    /// File the capture (`Organizer`), then (re)name its collection when due.
    func organize(_ id: String) async throws {
        guard let vector = try store.vector(id, space: .meaning) else { return }
        let all = try store.vectors(model: embeddingModel, space: .meaning)
        let byID = Dictionary(all.map { ($0.id, $0.vector) }, uniquingKeysWith: { a, _ in a })
        let captures = try store.captures(.recent, limit: 100_000)
        var members: [String: [[Float]]] = [:]
        var unsorted: [(id: String, vector: [Float])] = []
        for capture in captures where capture.id != id {
            guard let v = byID[capture.id] else { continue }
            if let collection = capture.collectionID {
                members[collection, default: []].append(v)
            } else if capture.stage == .organized {
                unsorted.append((capture.id, v))
            }
        }
        let groups = members.map { Organizer.Group(id: $0.key, members: $0.value) }

        var collectionID: String?
        switch organizer.decide(vector: vector, collections: groups, unsorted: unsorted) {
        case .join(let target, _):
            collectionID = target
        case .form(let others, _):
            let collection = CaptureCollection(name: "New collection", emoji: "📁")
            try store.insertCollection(collection)
            for other in others { try store.moveCapture(other, to: collection.id) }
            collectionID = collection.id
        case .stayUnsorted:
            collectionID = nil
        }
        try store.setCollection(id, collectionID: collectionID)
        if let collectionID {
            try store.touchCollection(collectionID)
            try await nameIfDue(collectionID)
        }
    }

    func nameIfDue(_ collectionID: String) async throws {
        guard let collection = try store.collections().first(where: { $0.id == collectionID }),
              Organizer.shouldRename(collection) else { return }
        let members = try store.captures(.collection(collectionID), limit: 12)
        let (name, emoji) = try await CollectionNamer(client: client, model: visionModel).name(members)
        try store.renameCollection(collectionID, name: name, emoji: emoji, namedAtCount: collection.count, byUser: false)
    }

    // MARK: - Finding

    /// Captures for `query`: the stand-outs by look and by meaning, and the
    /// word matches, merged.  When the embedding model is away, by words alone.
    public func search(_ query: String) async -> [Capture] {
        await findings(query).hits.map(\.capture)
    }

    /// The search with why each result came up and which collections it
    /// mostly found.
    public func findings(_ query: String) async -> SearchFindings {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchFindings(hits: [], collectionIDs: []) }
        var lists: [SearchReason: [String]] = [.words: ((try? store.textSearch(trimmed)) ?? []).map(\.id)]
        if let vector = try? await client.embed(model: embeddingModel, inputs: [.init(text: EmbeddingText.query(trimmed))]).first {
            for space in VectorSpace.allCases {
                let all = (try? store.vectors(model: embeddingModel, space: space)) ?? []
                lists[SearchReason(space)] = SearchMerge.standouts(SearchMerge.scores(vector, in: all)).map(\.id)
            }
        }
        // Words, then look, then meaning: the merge's ties keep this order stable.
        let found = SearchMerge.merge(SearchReason.allCases.compactMap { lists[$0] })
        let members = Dictionary(grouping: ((try? store.captures(.recent, limit: 100_000)) ?? [])
            .compactMap { c in c.collectionID.map { ($0, c.id) } }, by: \.0).mapValues { $0.map(\.1) }
        let ordered = SearchMerge.completingCollections(found, members: members)
        let reasons = SearchMerge.reasons(lists, completed: ordered)
        let captures = (try? store.captures(ids: ordered)) ?? []
        return SearchFindings(hits: captures.map { SearchHit(capture: $0, reasons: reasons[$0.id] ?? []) },
                              collectionIDs: SearchMerge.coveredCollections(found, members: members))
    }

    /// Below this, two captures' meanings are not related (different topics
    /// reach 0.79 at most in the measured set; same topic 0.795 and up).
    public static let relatedFloor: Float = 0.76

    /// The captures most like `id` in meaning, best first.
    public func related(to id: String, limit: Int = 8) -> [Capture] {
        guard let vector = try? store.vector(id, space: .meaning),
              let all = try? store.vectors(model: embeddingModel, space: .meaning) else { return [] }
        let near = SearchMerge.scores(vector, in: all, excluding: id)
            .filter { $0.score >= Self.relatedFloor }
            .sorted { $0.score > $1.score }
            .prefix(limit)
        return (try? store.captures(ids: near.map(\.id))) ?? []
    }

    // MARK: - Editing

    public func setNote(_ id: String, _ note: String?) async {
        try? store.setNote(id, note)
        await changed()
    }

    public func setFavorite(_ id: String, _ favorite: Bool) async {
        try? store.setFavorite(id, favorite)
        await changed()
    }

    public func setTags(_ id: String, _ tags: [String]) async {
        try? store.setTags(id, tags)
        await changed()
    }

    public func move(_ id: String, to collectionID: String?) async {
        try? store.moveCapture(id, to: collectionID)
        try? store.dropEmptyCollections()
        await changed()
    }

    public func renameCollection(_ id: String, name: String, emoji: String) async {
        let count = ((try? store.collections()) ?? []).first { $0.id == id }?.count ?? 0
        try? store.renameCollection(id, name: name, emoji: emoji, namedAtCount: count, byUser: true)
        await changed()
    }

    public func delete(_ id: String) async {
        try? store.delete(id)
        try? store.dropEmptyCollections()
        await changed()
    }

    // MARK: - Helpers

    private func changed() async {
        if let onChange { await onChange() }
    }

    /// The model sees at most 1,280 px on the long side (as much detail as a
    /// small vision model uses, and a fraction of the tokens).
    static func downscaled(_ png: Data) -> Data {
        Thumbnailer.jpeg(from: png, maxPixel: 1_280, quality: 0.85) ?? png
    }

    /// The reason to keep and when to try again: soon when Ollama is away,
    /// later when a model is missing or the answer was bad, backing off.
    static func retryPlan(for error: Error, attempt capture: Capture) -> (String, TimeInterval) {
        switch error {
        case OllamaClient.Failure.unreachable:
            return ("Ollama is not running", 60)
        case OllamaClient.Failure.server(let status, let message) where status == 404 || message.contains("not found"):
            return ("A model is missing: \(message)", 300)
        default:
            return (String(describing: error), 600)
        }
    }
}
