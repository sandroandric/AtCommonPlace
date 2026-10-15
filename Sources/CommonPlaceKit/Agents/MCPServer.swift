import Foundation

/// CommonPlace for agents: a Model Context Protocol server over stdio
/// (newline-delimited JSON-RPC 2.0).  Text only — titles, summaries,
/// passages, notes, tags, links, what was said — never images or files.
///
/// It runs only when the user adds it to an agent (`claude mcp add
/// commonplace -- …/CommonPlace.app/Contents/MacOS/commonplace-mcp`):
/// adding it is the consent.  It reads the library the app writes.
public final class MCPServer {
    public static let name = "commonplace"
    public static let protocolVersion = "2025-06-18"
    public static let instructions = """
        CommonPlace is the user's commonplace book: windows, photos and videos they chose to keep, each \
        described, tagged and filed into collections. Search it (search_commonplace) before asking the user \
        about something they saw, read or saved; open a result with get_capture for its full text.
        """

    let library: Library
    let store: LibraryStore
    let version: String

    public init(library: Library, store: LibraryStore, version: String) {
        self.library = library
        self.store = store
        self.version = version
    }

    // MARK: - Messages

    /// The reply to one message (a JSON object), or nil for a notification.
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(),
                                "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : Self.error(id, -32600, "Invalid request")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        // Notifications (no id) get no reply.
        guard let id else { return nil }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return Self.result(id, [
                "protocolVersion": asked ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.name, "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, arguments)
                return Self.result(id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch let failure as ToolFailure {
                return Self.result(id, ["content": [["type": "text", "text": failure.message]], "isError": true])
            } catch {
                return Self.result(id, ["content": [["type": "text", "text": "CommonPlace could not answer: \(error)"]], "isError": true])
            }
        default:
            return Self.error(id, -32601, "Method not found: \(method)")
        }
    }

    struct ToolFailure: Error {
        let message: String
    }

    // MARK: - Tools

    static let tools: [[String: Any]] = [
        [
            "name": "search_commonplace",
            "description": "Search what the user kept in CommonPlace (windows, photos, videos) by meaning and by words. Returns the best matches, newest information first within equal relevance.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look for, in plain words"],
                    "limit": ["type": "integer", "description": "At most this many results (default 8, at most 25)"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "recent_captures",
            "description": "What the user kept most recently, newest first; optionally only one collection or kind.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "At most this many (default 10, at most 50)"],
                    "collection": ["type": "string", "description": "A collection's name or id (list_collections)"],
                    "kind": ["type": "string", "description": "One of: \(CaptureKind.allCases.map(\.rawValue).joined(separator: ", "))"],
                ],
            ],
        ],
        [
            "name": "get_capture",
            "description": "One capture in full: title, summary, passages worth keeping, the user's note, tags, links, its collection, and the text on it or said in it.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The capture's id, from a search or listing"]],
                "required": ["id"],
            ],
        ],
        [
            "name": "list_collections",
            "description": "The collections CommonPlace formed (and the user named), with how many captures each holds.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        switch name {
        case "search_commonplace":
            guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw ToolFailure(message: "'query' must be a non-empty string.")
            }
            let limit = Self.limit(arguments["limit"], default: 8, max: 25)
            let found = await library.search(query).prefix(limit)
            if found.isEmpty { return "Nothing in CommonPlace matches “\(query)”." }
            return "CommonPlace for “\(query)” (\(found.count)):\n\n" + found.map(listing).joined(separator: "\n\n")
        case "recent_captures":
            let limit = Self.limit(arguments["limit"], default: 10, max: 50)
            var filter = LibraryFilter.recent
            if let wanted = arguments["collection"] as? String, !wanted.isEmpty {
                guard let collection = try store.collections().first(where: {
                    $0.id == wanted || $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame
                }) else {
                    throw ToolFailure(message: "No collection named “\(wanted)”. list_collections shows them.")
                }
                filter = .collection(collection.id)
            } else if let raw = arguments["kind"] as? String, !raw.isEmpty {
                guard let kind = CaptureKind(rawValue: raw.lowercased()) else {
                    throw ToolFailure(message: "Unknown kind “\(raw)”.")
                }
                filter = .kind(kind)
            }
            let captures = try store.captures(filter, limit: limit)
            if captures.isEmpty { return "Nothing kept there yet." }
            return captures.map(listing).joined(separator: "\n\n")
        case "get_capture":
            guard let id = arguments["id"] as? String, let capture = try store.capture(id) else {
                throw ToolFailure(message: "No capture with that id.")
            }
            return full(capture)
        case "list_collections":
            let collections = try store.collections().filter { $0.count > 0 }
            if collections.isEmpty { return "No collections yet: they form as similar captures are kept." }
            return collections.map { "\($0.emoji) \($0.name) — \($0.count) capture\($0.count == 1 ? "" : "s") (id \($0.id))" }
                .joined(separator: "\n")
        default:
            throw ToolFailure(message: "Unknown tool \(name).")
        }
    }

    // MARK: - Text

    private func collectionName(_ id: String?) -> String? {
        guard let id, let collection = try? store.collections().first(where: { $0.id == id }) else { return nil }
        return "\(collection.emoji) \(collection.name)"
    }

    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    /// A result: what it is, where from, when, and its summary.
    func listing(_ c: Capture) -> String {
        var lines = ["\(c.displayTitle) — \(c.kind?.title ?? c.media.title)"]
        var facts = ["id \(c.id)", c.url ?? c.sourceName, (c.takenAt ?? c.createdAt).formatted(Self.dateFormat)]
        if let collection = collectionName(c.collectionID) { facts.append(collection) }
        lines.append(facts.joined(separator: " · "))
        if let summary = c.summary, !summary.isEmpty { lines.append(summary) }
        if let note = c.note, !note.isEmpty { lines.append("Note: \(note)") }
        if !c.tags.isEmpty { lines.append("Tags: " + c.tags.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// Everything readable about a capture (long texts capped).
    func full(_ c: Capture) -> String {
        var parts = [listing(c)]
        if c.media == .video, let duration = c.duration { parts.append("Video, \(Int(duration.rounded())) seconds.") }
        if !c.highlights.isEmpty { parts.append("Worth keeping:\n" + c.highlights.map { "“\($0)”" }.joined(separator: "\n")) }
        if !c.links.isEmpty { parts.append("Links:\n" + c.links.joined(separator: "\n")) }
        if let transcript = c.transcript, !transcript.isEmpty { parts.append("Said in it:\n" + Self.capped(transcript)) }
        if let text = c.ocrText, !text.isEmpty { parts.append("Text on it:\n" + Self.capped(text)) }
        if c.stage != .organized { parts.append("(Still being read: the description may be incomplete.)") }
        return parts.joined(separator: "\n\n")
    }

    static func capped(_ text: String, max: Int = 4_000) -> String {
        text.count > max ? String(text.prefix(max)) + "…" : text
    }

    static func limit(_ value: Any?, default fallback: Int, max: Int) -> Int {
        guard let number = value as? Int else { return fallback }
        return Swift.max(1, Swift.min(number, max))
    }

    // MARK: - JSON-RPC

    static func result(_ id: Any, _ result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(_ id: Any?, _ code: Int, _ message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
