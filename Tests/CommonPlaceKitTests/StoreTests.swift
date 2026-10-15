import XCTest
@testable import CommonPlaceKit

final class StoreTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-\(UUID().uuidString)")
        store = try LibraryStore(root: root)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func keep(_ title: String, app: String = "Safari", url: String? = nil, at seconds: Double = 0) throws -> Capture {
        let capture = Capture(createdAt: Date(timeIntervalSince1970: 1_000_000 + seconds), app: app,
                              windowTitle: title, url: url, width: 1200, height: 800)
        try store.insert(capture)
        return capture
    }

    func testACaptureGoesThroughItsStages() throws {
        let c = try keep("Starter guide", url: "https://www.bakewithme.com/guide")
        XCTAssertEqual(try store.pending().map(\.id), [c.id])
        try store.setRead(c.id, ocrText: "Feed it every 12 hours")
        try store.setDescribed(c.id, CaptureDescription(title: "Feeding a starter", summary: "How.", kind: .recipe,
                                                        tags: ["Sourdough", "#baking"], highlights: ["Feed it"],
                                                        links: ["https://bakewithme.com"]))
        try store.setEmbedding(c.id, model: "m", vectors: [.look: [0.6, 0.8], .meaning: [1, 0]])
        try store.setCollection(c.id, collectionID: nil)
        let stored = try XCTUnwrap(try store.capture(c.id))
        XCTAssertEqual(stored.stage, .organized)
        XCTAssertEqual(stored.title, "Feeding a starter")
        XCTAssertEqual(stored.kind, .recipe)
        XCTAssertEqual(stored.tags, ["baking", "sourdough"])
        XCTAssertEqual(stored.highlights, ["Feed it"])
        XCTAssertEqual(stored.sourceName, "bakewithme.com")
        XCTAssertEqual(try store.vector(c.id, space: .look), [0.6, 0.8])
        XCTAssertEqual(try store.vector(c.id, space: .meaning), [1, 0])
        XCTAssertEqual(try store.pending(), [])
        XCTAssertEqual(try store.kindCounts().map(\.0), [.recipe])
        XCTAssertEqual(try store.sourceCounts().first?.0, "bakewithme.com")
    }

    func testAFailedStageWaitsBeforeTheNextTry() throws {
        let c = try keep("x")
        let now = Date()
        try store.recordFailure(c.id, error: "Ollama is not running", retryAfter: 60, now: now)
        XCTAssertEqual(try store.pending(now: now), [])
        XCTAssertEqual(try store.pending(now: now.addingTimeInterval(61)).map(\.id), [c.id])
        XCTAssertEqual(try store.capture(c.id)?.lastError, "Ollama is not running")
    }

    func testWordsFindTitleOCRNoteAndTags() throws {
        let a = try keep("Starter guide")
        let b = try keep("Quarterly numbers", app: "Numbers")
        try store.setRead(a.id, ocrText: "Feed the starter every twelve hours")
        try store.setNote(b.id, "for the board meeting")
        try store.setTags(b.id, ["finance"])
        XCTAssertEqual(try store.textSearch("twelve").map(\.id), [a.id])
        XCTAssertEqual(try store.textSearch("board meet").map(\.id), [b.id], "prefix match")
        XCTAssertEqual(try store.textSearch("finance").map(\.id), [b.id])
        XCTAssertEqual(try store.textSearch("guide").map(\.id), [a.id])
        XCTAssertEqual(try store.textSearch("the starter guide").map(\.id), [a.id], "stopwords left out")
        XCTAssertTrue(try store.textSearch("  ").isEmpty)
    }

    func testCollectionsCountTheirMembersAndEmptyOnesGo() throws {
        let a = try keep("a"), b = try keep("b", at: 10)
        let collection = CaptureCollection(name: "Bread", emoji: "🍞")
        try store.insertCollection(collection)
        try store.moveCapture(a.id, to: collection.id)
        try store.moveCapture(b.id, to: collection.id)
        XCTAssertEqual(try store.collections().first?.count, 2)
        XCTAssertEqual(try store.captures(.collection(collection.id)).map(\.id), [b.id, a.id], "newest first")
        try store.renameCollection(collection.id, name: "Baking", emoji: "🥖", namedAtCount: 2, byUser: true)
        XCTAssertEqual(try store.collections().first?.name, "Baking")
        XCTAssertEqual(try store.collections().first?.userNamed, true)
        try store.moveCapture(a.id, to: nil)
        try store.moveCapture(b.id, to: nil)
        try store.dropEmptyCollections()
        XCTAssertEqual(try store.collections(), [])
        XCTAssertEqual(Set(try store.captures(.unsorted).map(\.id)), [a.id, b.id])
    }

    func testDeletingRemovesTheRowItsIndexAndItsImages() throws {
        let c = try keep("Starter")
        try Data("png".utf8).write(to: store.imageURL(c.id))
        try Data("jpg".utf8).write(to: store.thumbURL(c.id))
        try store.setEmbedding(c.id, model: "m", vectors: [.look: [1], .meaning: [1]])
        try store.delete(c.id)
        XCTAssertNil(try store.capture(c.id))
        XCTAssertTrue(try store.textSearch("starter").isEmpty)
        XCTAssertEqual(try store.vectors(model: "m", space: .look).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(c.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.thumbURL(c.id).path))
    }

    func testReopeningKeepsEverything() throws {
        let c = try keep("Starter")
        store = nil
        store = try LibraryStore(root: root)
        XCTAssertEqual(try store.capture(c.id)?.windowTitle, "Starter")
        XCTAssertEqual(try store.count(), 1)
    }

    func testTimeShelves() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        // Wednesday 14 October 2026, 15:00 UTC.
        let now = Date(timeIntervalSince1970: 1_791_990_000)
        XCTAssertEqual(TimeShelf.today.start(now: now, calendar: calendar), Date(timeIntervalSince1970: 1_791_936_000))
        XCTAssertEqual(TimeShelf.thisWeek.start(now: now, calendar: calendar), Date(timeIntervalSince1970: 1_791_763_200), "Monday")
        XCTAssertEqual(TimeShelf.thisMonth.start(now: now, calendar: calendar), Date(timeIntervalSince1970: 1_790_812_800), "1 October")

        let old = Capture(createdAt: now.addingTimeInterval(-3 * 86_400), app: "a", windowTitle: "old", width: 1, height: 1)
        let fresh = Capture(createdAt: now.addingTimeInterval(-600), app: "a", windowTitle: "fresh", width: 1, height: 1)
        try store.insert(old)
        try store.insert(fresh)
        let today = TimeShelf.today.start(now: now, calendar: calendar)
        XCTAssertEqual(try store.captures(.since(today)).map(\.id), [fresh.id])
        XCTAssertEqual(try store.count(since: today), 1)
        XCTAssertEqual(try store.count(since: TimeShelf.thisMonth.start(now: now, calendar: calendar)), 2)
    }

    func testFavoritesAndShelves() throws {
        let a = try keep("a", url: "https://github.com/x"), b = try keep("b", at: 5)
        try store.setFavorite(a.id, true)
        XCTAssertEqual(try store.captures(.favorites).map(\.id), [a.id])
        XCTAssertEqual(try store.captures(.source("github.com")).map(\.id), [a.id])
        XCTAssertEqual(try store.captures(.recent).map(\.id), [b.id, a.id])
        XCTAssertEqual(try store.captures(ids: [a.id, b.id]).map(\.id), [a.id, b.id], "in the order asked")
    }
}
