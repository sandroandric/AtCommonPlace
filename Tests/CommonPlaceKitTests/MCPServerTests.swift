import XCTest
@testable import CommonPlaceKit

final class MCPServerTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private var server: MCPServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-mcp-\(UUID().uuidString)")
        store = try LibraryStore(root: root)
        // Ollama unreachable: search must still answer, by words.
        let library = Library(store: store, client: OllamaClient(host: URL(string: "http://127.0.0.1:9")!))
        server = MCPServer(library: library, store: store, version: "0.1.0")

        let espresso = Capture(id: "c1", createdAt: Date(timeIntervalSince1970: 1_000), app: "Comet",
                               windowTitle: "Espresso - Wikipedia", url: "https://en.wikipedia.org/wiki/Espresso",
                               width: 800, height: 900)
        try store.insert(espresso)
        try store.setRead("c1", ocrText: "Espresso is a concentrated form of coffee")
        try store.setDescribed("c1", CaptureDescription(title: "Espresso", summary: "How espresso is made.", kind: .article,
                                                        tags: ["coffee"], highlights: ["Espresso is a concentrated form of coffee"],
                                                        links: ["https://en.wikipedia.org/wiki/Espresso"]))
        let collection = CaptureCollection(name: "Coffee Drinks", emoji: "☕")
        try store.insertCollection(collection)
        try store.setCollection("c1", collectionID: collection.id)
        try store.setNote("c1", "for the café idea")
        let clip = Capture(id: "v1", createdAt: Date(timeIntervalSince1970: 2_000), app: "Videos", windowTitle: "kyoto",
                           width: 320, height: 180, media: .video, duration: 42)
        try store.insert(clip)
        try store.setRead("v1", ocrText: "", transcript: "Welcome to the bamboo forest in Kyoto.")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func send(_ message: [String: Any]) async throws -> [String: Any] {
        let line = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        let answer = await server.handle(line)
        let reply = try XCTUnwrap(answer)
        XCTAssertFalse(reply.contains("\n"), "one line per message")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
        let reply = try await send(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                    "params": ["name": tool, "arguments": arguments]])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (content, result["isError"] as? Bool ?? false)
    }

    func testTheHandshake() async throws {
        let reply = try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": ["protocolVersion": "2025-03-26", "capabilities": [:],
                                               "clientInfo": ["name": "test", "version": "1"]]])
        XCTAssertEqual(reply["id"] as? Int, 1)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26", "the client's version is answered")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "commonplace")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        // A notification gets no reply.
        let quiet = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(quiet)
        let tools = try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["search_commonplace", "recent_captures", "get_capture", "list_collections"])
    }

    func testSearchAnswersByWordsWhenTheModelIsAway() async throws {
        let (text, isError) = try await call("search_commonplace", ["query": "concentrated coffee"])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("Espresso — Articles"), text)
        XCTAssertTrue(text.contains("id c1"))
        XCTAssertTrue(text.contains("☕ Coffee Drinks"))
        XCTAssertTrue(text.contains("Note: for the café idea"))
        let said = try await call("search_commonplace", ["query": "bamboo"])
        XCTAssertTrue(said.text.contains("id v1"), "a video's transcript is searchable: \(said.text)")
        let none = try await call("search_commonplace", ["query": "submarine"])
        XCTAssertEqual(none.text, "Nothing in CommonPlace matches “submarine”.")
        let bad = try await call("search_commonplace", ["query": "  "])
        XCTAssertTrue(bad.isError)
    }

    func testRecentGetAndCollections() async throws {
        let recent = try await call("recent_captures", ["limit": 1])
        XCTAssertTrue(recent.text.hasPrefix("kyoto — Videos"), recent.text)
        let inCollection = try await call("recent_captures", ["collection": "coffee drinks"])
        XCTAssertTrue(inCollection.text.hasPrefix("Espresso"), inCollection.text)
        let unknown = try await call("recent_captures", ["collection": "Nope"])
        XCTAssertTrue(unknown.isError)

        let full = try await call("get_capture", ["id": "c1"])
        XCTAssertTrue(full.text.contains("Worth keeping:\n“Espresso is a concentrated form of coffee”"), full.text)
        XCTAssertTrue(full.text.contains("https://en.wikipedia.org/wiki/Espresso"))
        let video = try await call("get_capture", ["id": "v1"])
        XCTAssertTrue(video.text.contains("Video, 42 seconds."))
        XCTAssertTrue(video.text.contains("Said in it:\nWelcome to the bamboo forest in Kyoto."))
        XCTAssertTrue(video.text.contains("Still being read"))
        let missing = try await call("get_capture", ["id": "nope"])
        XCTAssertTrue(missing.isError)

        let collections = try await call("list_collections")
        XCTAssertTrue(collections.text.hasPrefix("☕ Coffee Drinks — 1 capture (id "), collections.text)
    }

    func testBadInputIsAnErrorNotACrash() async throws {
        let garbage = await server.handle("{not json")
        XCTAssertTrue(garbage?.contains("-32700") == true)
        let unknown = try await send(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let tool = try await call("delete_everything")
        XCTAssertTrue(tool.isError)
    }
}
