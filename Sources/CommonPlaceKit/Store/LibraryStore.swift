import Foundation

/// Which captures a library view shows.
public enum LibraryFilter: Hashable, Sendable {
    case recent
    case favorites
    case collection(String)
    case kind(CaptureKind)
    case source(String)
    case unsorted
    /// Kept at or after this moment.
    case since(Date)
    case media(CaptureMedia)
}

/// The time shelves: today, this week, this month (the user's calendar).
public enum TimeShelf: String, CaseIterable, Sendable {
    case today, thisWeek, thisMonth

    public var title: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        }
    }

    /// Where the shelf starts, for `now` in `calendar`.
    public func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        case .thisMonth: return calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        }
    }
}

/// The library on disk: `library.sqlite` and the images beside it.
///
/// `<root>/library.sqlite` holds captures, collections, tags, vectors and a
/// full-text index; `<root>/captures/<id>.png` is the full window,
/// `<root>/thumbs/<id>.jpg` its card thumbnail.  Not thread-safe: the app
/// uses it from one actor (`Library`).
public final class LibraryStore {
    public static let schemaVersion = 2

    public let root: URL
    let db: Database

    public init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        for dir in [root, root.appendingPathComponent("captures"), root.appendingPathComponent("thumbs"),
                    root.appendingPathComponent("media")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        db = try Database(path: root.appendingPathComponent("library.sqlite").path)
        try migrate()
    }

    /// The default library: `~/Library/Application Support/CommonPlace`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CommonPlace", isDirectory: true)
    }

    public func imageURL(_ id: String) -> URL { root.appendingPathComponent("captures/\(id).png") }
    /// The picture the library shows for `capture` (a window's PNG, an import's JPEG).
    public func imageURL(for capture: Capture) -> URL {
        capture.imageFile.map { root.appendingPathComponent($0) } ?? imageURL(capture.id)
    }
    public func originalURL(for capture: Capture) -> URL? {
        capture.originalFile.map { root.appendingPathComponent($0) }
    }
    /// A video's contact sheet: what the models look at.
    public func sheetURL(_ id: String) -> URL { root.appendingPathComponent("media/\(id)-sheet.jpg") }
    public func thumbURL(_ id: String) -> URL { root.appendingPathComponent("thumbs/\(id).jpg") }

    // MARK: - Schema

    private func migrate() throws {
        let version = db.userVersion
        guard version < Self.schemaVersion else { return }
        try db.transaction {
            if version < 1 {
                try db.execute("""
                    CREATE TABLE captures (
                        id TEXT PRIMARY KEY NOT NULL,
                        created_at REAL NOT NULL,
                        app TEXT NOT NULL DEFAULT '',
                        bundle_id TEXT,
                        window_title TEXT NOT NULL DEFAULT '',
                        url TEXT,
                        document_path TEXT,
                        source TEXT NOT NULL DEFAULT '',
                        width INTEGER NOT NULL DEFAULT 0,
                        height INTEGER NOT NULL DEFAULT 0,
                        stage TEXT NOT NULL DEFAULT 'captured',
                        ocr_text TEXT,
                        title TEXT,
                        summary TEXT,
                        kind TEXT,
                        highlights TEXT NOT NULL DEFAULT '[]',
                        links TEXT NOT NULL DEFAULT '[]',
                        note TEXT,
                        favorite INTEGER NOT NULL DEFAULT 0,
                        collection_id TEXT REFERENCES collections(id) ON DELETE SET NULL,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        next_attempt_at REAL NOT NULL DEFAULT 0,
                        last_error TEXT
                    );
                    CREATE INDEX idx_captures_created ON captures(created_at);
                    CREATE INDEX idx_captures_stage ON captures(stage, next_attempt_at);
                    CREATE INDEX idx_captures_collection ON captures(collection_id);
                    CREATE INDEX idx_captures_kind ON captures(kind);
                    CREATE INDEX idx_captures_source ON captures(source);

                    CREATE TABLE capture_tags (
                        capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                        tag TEXT NOT NULL,
                        PRIMARY KEY (capture_id, tag)
                    );
                    CREATE INDEX idx_capture_tags_tag ON capture_tags(tag);

                    CREATE TABLE collections (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        emoji TEXT NOT NULL DEFAULT '',
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        named_at_count INTEGER NOT NULL DEFAULT 0,
                        user_named INTEGER NOT NULL DEFAULT 0
                    );

                    CREATE TABLE vectors (
                        capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                        space TEXT NOT NULL,
                        model TEXT NOT NULL,
                        dim INTEGER NOT NULL,
                        vector BLOB NOT NULL,
                        PRIMARY KEY (capture_id, space)
                    );

                    CREATE VIRTUAL TABLE captures_fts USING fts5(
                        id UNINDEXED, title, summary, ocr, note, tags, source,
                        tokenize = 'porter unicode61 remove_diacritics 2'
                    );
                    """)
            }
            if version < 2 {
                try db.execute("""
                    ALTER TABLE captures ADD COLUMN media TEXT NOT NULL DEFAULT 'screen';
                    ALTER TABLE captures ADD COLUMN duration REAL;
                    ALTER TABLE captures ADD COLUMN taken_at REAL;
                    ALTER TABLE captures ADD COLUMN image_file TEXT;
                    ALTER TABLE captures ADD COLUMN original_file TEXT;
                    ALTER TABLE captures ADD COLUMN transcript TEXT;
                    CREATE INDEX idx_captures_media ON captures(media);
                    """)
            }
            try db.setUserVersion(Self.schemaVersion)
        }
    }

    // MARK: - Writing

    public func insert(_ capture: Capture) throws {
        try db.transaction {
            try db.run("""
                INSERT INTO captures (id, created_at, app, bundle_id, window_title, url, document_path,
                    source, width, height, stage, note, favorite, media, duration, taken_at, image_file, original_file)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(capture.id), .double(capture.createdAt.timeIntervalSince1970),
                    .text(capture.app), capture.bundleID.sqlValue, .text(capture.windowTitle),
                    capture.url.sqlValue, capture.documentPath.sqlValue, .text(capture.sourceName),
                    .int(Int64(capture.width)), .int(Int64(capture.height)),
                    .text(capture.stage.rawValue), capture.note.sqlValue, .int(capture.favorite ? 1 : 0),
                    .text(capture.media.rawValue), capture.duration.map { .double($0) } ?? .null,
                    capture.takenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    capture.imageFile.sqlValue, capture.originalFile.sqlValue,
                ])
            try reindex(capture.id)
        }
    }

    public func setRead(_ id: String, ocrText: String, transcript: String? = nil) throws {
        try db.transaction {
            try db.run("UPDATE captures SET ocr_text = ?, transcript = ?, stage = ?, attempts = 0, last_error = NULL WHERE id = ?",
                       [.text(ocrText), transcript.sqlValue, .text(CaptureStage.read.rawValue), .text(id)])
            try reindex(id)
        }
    }

    public func setDescribed(_ id: String, _ description: CaptureDescription) throws {
        try db.transaction {
            try db.run("""
                UPDATE captures SET title = ?, summary = ?, kind = ?, highlights = ?, links = ?,
                    stage = ?, attempts = 0, last_error = NULL WHERE id = ?
                """, [
                    .text(description.title), .text(description.summary), .text(description.kind.rawValue),
                    .text(Self.json(description.highlights)), .text(Self.json(description.links)),
                    .text(CaptureStage.described.rawValue), .text(id),
                ])
            try writeTags(id, description.tags)
            try reindex(id)
        }
    }

    /// Store the capture's vectors (one per space) and mark it embedded.
    public func setEmbedding(_ id: String, model: String, vectors: [VectorSpace: [Float]]) throws {
        try db.transaction {
            for (space, vector) in vectors {
                try db.run("INSERT OR REPLACE INTO vectors (capture_id, space, model, dim, vector) VALUES (?, ?, ?, ?, ?)",
                           [.text(id), .text(space.rawValue), .text(model), .int(Int64(vector.count)), .blob(Self.data(vector))])
            }
            try db.run("UPDATE captures SET stage = ?, attempts = 0, last_error = NULL WHERE id = ?",
                       [.text(CaptureStage.embedded.rawValue), .text(id)])
        }
    }

    public func setCollection(_ id: String, collectionID: String?) throws {
        try db.run("UPDATE captures SET collection_id = ?, stage = ?, attempts = 0, last_error = NULL WHERE id = ?",
                   [collectionID.sqlValue, .text(CaptureStage.organized.rawValue), .text(id)])
    }

    /// A stage failed: keep the reason, retry after `retryAfter` seconds.
    public func recordFailure(_ id: String, error: String, retryAfter: TimeInterval, now: Date = Date()) throws {
        try db.run("UPDATE captures SET attempts = attempts + 1, last_error = ?, next_attempt_at = ? WHERE id = ?",
                   [.text(error), .double(now.timeIntervalSince1970 + retryAfter), .text(id)])
    }

    public func setNote(_ id: String, _ note: String?) throws {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.transaction {
            try db.run("UPDATE captures SET note = ? WHERE id = ?",
                       [(trimmed?.isEmpty == false ? trimmed : nil).sqlValue, .text(id)])
            try reindex(id)
        }
    }

    public func setFavorite(_ id: String, _ favorite: Bool) throws {
        try db.run("UPDATE captures SET favorite = ? WHERE id = ?", [.int(favorite ? 1 : 0), .text(id)])
    }

    public func setTags(_ id: String, _ tags: [String]) throws {
        try db.transaction {
            try writeTags(id, tags)
            try reindex(id)
        }
    }

    /// Delete a capture: its row (tags and vector follow), index entry, images and original.
    public func delete(_ id: String) throws {
        let existing = try capture(id)
        try db.transaction {
            try db.run("DELETE FROM captures_fts WHERE id = ?", [.text(id)])
            try db.run("DELETE FROM captures WHERE id = ?", [.text(id)])
        }
        var files = [imageURL(id), thumbURL(id), sheetURL(id)]
        if let existing {
            files.append(imageURL(for: existing))
            if let original = originalURL(for: existing) { files.append(original) }
        }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Collections

    public func insertCollection(_ collection: CaptureCollection) throws {
        try db.run("""
            INSERT INTO collections (id, name, emoji, created_at, updated_at, named_at_count, user_named)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(collection.id), .text(collection.name), .text(collection.emoji),
                .double(collection.createdAt.timeIntervalSince1970), .double(collection.updatedAt.timeIntervalSince1970),
                .int(Int64(collection.namedAtCount)), .int(collection.userNamed ? 1 : 0),
            ])
    }

    public func renameCollection(_ id: String, name: String, emoji: String, namedAtCount: Int, byUser: Bool) throws {
        try db.run("""
            UPDATE collections SET name = ?, emoji = ?, named_at_count = ?, updated_at = ?,
                user_named = CASE WHEN ? THEN 1 ELSE user_named END
            WHERE id = ?
            """, [.text(name), .text(emoji), .int(Int64(namedAtCount)), .double(Date().timeIntervalSince1970),
                  .int(byUser ? 1 : 0), .text(id)])
    }

    /// Move a capture into `collectionID` (nil: out of every collection).
    public func moveCapture(_ id: String, to collectionID: String?) throws {
        try db.run("UPDATE captures SET collection_id = ? WHERE id = ?", [collectionID.sqlValue, .text(id)])
    }

    /// Remove collections nobody is in.
    public func dropEmptyCollections() throws {
        try db.run("DELETE FROM collections WHERE id NOT IN (SELECT collection_id FROM captures WHERE collection_id IS NOT NULL)")
    }

    public func collections() throws -> [CaptureCollection] {
        try db.query("""
            SELECT c.*, (SELECT count(*) FROM captures WHERE collection_id = c.id) AS n
            FROM collections c ORDER BY c.updated_at DESC
            """).map { row in
            CaptureCollection(
                id: row["id"]?.text ?? "", name: row["name"]?.text ?? "", emoji: row["emoji"]?.text ?? "",
                createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0),
                count: Int(row["n"]?.int ?? 0), namedAtCount: Int(row["named_at_count"]?.int ?? 0),
                userNamed: (row["user_named"]?.int ?? 0) != 0
            )
        }
    }

    public func touchCollection(_ id: String) throws {
        try db.run("UPDATE collections SET updated_at = ? WHERE id = ?", [.double(Date().timeIntervalSince1970), .text(id)])
    }

    // MARK: - Reading

    public func capture(_ id: String) throws -> Capture? {
        try captures(where: "c.id = ?", [.text(id)], limit: 1).first
    }

    public func captures(_ filter: LibraryFilter, limit: Int = 500) throws -> [Capture] {
        switch filter {
        case .recent: return try captures(where: "1", [], limit: limit)
        case .favorites: return try captures(where: "c.favorite = 1", [], limit: limit)
        case .collection(let id): return try captures(where: "c.collection_id = ?", [.text(id)], limit: limit)
        case .kind(let kind): return try captures(where: "c.kind = ?", [.text(kind.rawValue)], limit: limit)
        case .source(let source): return try captures(where: "c.source = ?", [.text(source)], limit: limit)
        case .unsorted: return try captures(where: "c.collection_id IS NULL", [], limit: limit)
        case .since(let date): return try captures(where: "c.created_at >= ?", [.double(date.timeIntervalSince1970)], limit: limit)
        case .media(let media): return try captures(where: "c.media = ?", [.text(media.rawValue)], limit: limit)
        }
    }

    public func captures(ids: [String]) throws -> [Capture] {
        guard !ids.isEmpty else { return [] }
        let found = try captures(where: "c.id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))",
                                 ids.map { .text($0) }, limit: ids.count)
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Captures still being understood, due now, oldest first.
    public func pending(now: Date = Date(), limit: Int = 20) throws -> [Capture] {
        try captures(where: "c.stage != ? AND c.next_attempt_at <= ?",
                     [.text(CaptureStage.organized.rawValue), .double(now.timeIntervalSince1970)],
                     limit: limit, order: "c.created_at ASC")
    }

    public func kindCounts() throws -> [(CaptureKind, Int)] {
        try db.query("SELECT kind, count(*) AS n FROM captures WHERE kind IS NOT NULL GROUP BY kind ORDER BY n DESC")
            .compactMap { row in
                guard let raw = row["kind"]?.text, let kind = CaptureKind(rawValue: raw) else { return nil }
                return (kind, Int(row["n"]?.int ?? 0))
            }
    }

    public func mediaCounts() throws -> [CaptureMedia: Int] {
        var counts: [CaptureMedia: Int] = [:]
        for row in try db.query("SELECT media, count(*) AS n FROM captures GROUP BY media") {
            if let media = row["media"]?.text.flatMap(CaptureMedia.init(rawValue:)) { counts[media] = Int(row["n"]?.int ?? 0) }
        }
        return counts
    }

    /// Sites and apps windows were kept from (photos and videos have their own shelves).
    public func sourceCounts(limit: Int = 30) throws -> [(String, Int)] {
        try db.query("SELECT source, count(*) AS n FROM captures WHERE source != '' AND media = 'screen' GROUP BY source ORDER BY n DESC, source LIMIT ?",
                     [.int(Int64(limit))])
            .map { ($0["source"]?.text ?? "", Int($0["n"]?.int ?? 0)) }
    }

    public func count() throws -> Int {
        Int(try db.query("SELECT count(*) AS n FROM captures").first?["n"]?.int ?? 0)
    }

    public func count(since date: Date) throws -> Int {
        Int(try db.query("SELECT count(*) AS n FROM captures WHERE created_at >= ?",
                         [.double(date.timeIntervalSince1970)]).first?["n"]?.int ?? 0)
    }

    /// Every stored vector of `model` in `space`.
    public func vectors(model: String, space: VectorSpace) throws -> [(id: String, vector: [Float])] {
        try db.query("SELECT capture_id, vector FROM vectors WHERE model = ? AND space = ?",
                     [.text(model), .text(space.rawValue)]).compactMap { row in
            guard let id = row["capture_id"]?.text, let data = row["vector"]?.blob else { return nil }
            return (id, Self.floats(data))
        }
    }

    public func vector(_ id: String, space: VectorSpace) throws -> [Float]? {
        try db.query("SELECT vector FROM vectors WHERE capture_id = ? AND space = ?", [.text(id), .text(space.rawValue)])
            .first?["vector"]?.blob.map(Self.floats)
    }

    /// Full-text matches for `query` (words, prefix-matched), best first.
    public func textSearch(_ query: String, limit: Int = 100) throws -> [(id: String, rank: Double)] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        return try db.query("SELECT id, bm25(captures_fts) AS r FROM captures_fts WHERE captures_fts MATCH ? ORDER BY r LIMIT ?",
                            [.text(match), .int(Int64(limit))])
            .compactMap { row in row["id"]?.text.map { ($0, row["r"]?.double ?? 0) } }
    }

    // MARK: - Internals

    private func captures(where clause: String, _ values: [Database.Value], limit: Int,
                          order: String = "c.created_at DESC") throws -> [Capture] {
        let rows = try db.query("""
            SELECT c.*, (SELECT group_concat(tag, char(31)) FROM capture_tags WHERE capture_id = c.id) AS tag_list
            FROM captures c WHERE \(clause) ORDER BY \(order) LIMIT ?
            """, values + [.int(Int64(limit))])
        return rows.map(Self.capture)
    }

    private static func capture(_ row: Database.Row) -> Capture {
        Capture(
            id: row["id"]?.text ?? "",
            createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
            app: row["app"]?.text ?? "",
            bundleID: row["bundle_id"]?.text,
            windowTitle: row["window_title"]?.text ?? "",
            url: row["url"]?.text,
            documentPath: row["document_path"]?.text,
            width: Int(row["width"]?.int ?? 0),
            height: Int(row["height"]?.int ?? 0),
            stage: CaptureStage(rawValue: row["stage"]?.text ?? "") ?? .captured,
            ocrText: row["ocr_text"]?.text,
            title: row["title"]?.text,
            summary: row["summary"]?.text,
            kind: row["kind"]?.text.flatMap(CaptureKind.init(rawValue:)),
            tags: (row["tag_list"]?.text ?? "").split(separator: "\u{1F}").map(String.init).sorted(),
            highlights: strings(row["highlights"]?.text),
            links: strings(row["links"]?.text),
            note: row["note"]?.text,
            favorite: (row["favorite"]?.int ?? 0) != 0,
            collectionID: row["collection_id"]?.text,
            lastError: row["last_error"]?.text,
            media: CaptureMedia(rawValue: row["media"]?.text ?? "") ?? .screen,
            duration: row["duration"]?.double,
            takenAt: row["taken_at"]?.double.map(Date.init(timeIntervalSince1970:)),
            imageFile: row["image_file"]?.text,
            originalFile: row["original_file"]?.text,
            transcript: row["transcript"]?.text
        )
    }

    private func writeTags(_ id: String, _ tags: [String]) throws {
        try db.run("DELETE FROM capture_tags WHERE capture_id = ?", [.text(id)])
        for tag in Set(tags.map(Self.normalizedTag).filter { !$0.isEmpty }) {
            try db.run("INSERT INTO capture_tags (capture_id, tag) VALUES (?, ?)", [.text(id), .text(tag)])
        }
    }

    /// Rebuild the capture's full-text row from what is stored now.
    private func reindex(_ id: String) throws {
        try db.run("DELETE FROM captures_fts WHERE id = ?", [.text(id)])
        try db.run("""
            INSERT INTO captures_fts (id, title, summary, ocr, note, tags, source)
            SELECT c.id, coalesce(c.title, '') || ' ' || c.window_title, coalesce(c.summary, ''),
                coalesce(c.ocr_text, '') || ' ' || coalesce(c.transcript, ''), coalesce(c.note, ''),
                coalesce((SELECT group_concat(tag, ' ') FROM capture_tags WHERE capture_id = c.id), ''),
                c.source || ' ' || c.app
            FROM captures c WHERE c.id = ?
            """, [.text(id)])
    }

    /// Words that say nothing about what is wanted ("a", "the", "of"…):
    /// left out of word search, where every word must match.
    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "and", "or", "with", "about", "from",
        "that", "this", "what", "was", "is", "it", "my", "i", "me", "some", "page", "screen",
    ]

    public static func normalizedTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#")))
            .lowercased()
    }

    /// The words of `query` as an FTS5 query: each word quoted, prefix-matched, all required.
    static func ftsQuery(_ query: String) -> String {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
    }

    static func json(_ strings: [String]) -> String {
        (try? String(data: JSONEncoder().encode(strings), encoding: .utf8)) ?? "[]"
    }

    static func strings(_ text: String?) -> [String] {
        guard let data = text?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
