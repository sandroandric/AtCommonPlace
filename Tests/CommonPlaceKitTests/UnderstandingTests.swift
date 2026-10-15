import XCTest
@testable import CommonPlaceKit

final class DescriberTests: XCTestCase {
    private let ocr = """
        Sourdough starter
        Feed it every 12 hours with equal weights of flour and water.
        Keep at 24°C for a lively rise.
        More at bakewithme.com/starter
        """

    func testAGoodAnswerIsKeptAndChecked() throws {
        let answer = """
            Here you go: {"title": "  Feeding a sourdough starter ", "summary": "How often to feed a starter and at what temperature.",
             "kind": "Recipe", "tags": ["#Sourdough", "baking", "baking", "Bread Making", "fermentation", "flour", "extra"],
             "highlights": ["Feed it every 12 hours with equal weights of flour and water.", "Invented passage not on screen"],
             "links": ["bakewithme.com/starter", "https://made-up.example.com/x"]}
            """
        let d = try Describer.parse(answer, ocrText: ocr, url: "https://www.bakewithme.com/guide", fallbackTitle: "Safari")
        XCTAssertEqual(d.title, "Feeding a sourdough starter")
        XCTAssertEqual(d.kind, .recipe)
        XCTAssertEqual(d.tags, ["sourdough", "baking", "bread making", "fermentation", "flour"])
        XCTAssertEqual(d.highlights, ["Feed it every 12 hours with equal weights of flour and water."], "only passages on the screen")
        XCTAssertEqual(d.links, ["https://www.bakewithme.com/guide", "https://bakewithme.com/starter"], "no invented links")
    }

    func testAThinAnswerFallsBack() throws {
        let d = try Describer.parse(#"{"kind": "web page"}"#, ocrText: "", url: nil, fallbackTitle: "Report.pdf")
        XCTAssertEqual(d.title, "Report.pdf")
        XCTAssertEqual(d.summary, "")
        XCTAssertEqual(d.kind, .article)
        XCTAssertEqual(d.tags, [])
        XCTAssertEqual(CaptureKind.parse("drink"), .food)
        XCTAssertEqual(CaptureKind.parse("Food"), .food)
    }

    /// Real openings from the evaluation, and summaries that must stay as they are.
    func testTheScreenshotPreambleIsDropped() {
        XCTAssertEqual(Describer.withoutPreamble("A screenshot of the Excalidraw whiteboard application showing its main interface."),
                       "Excalidraw whiteboard application showing its main interface.")
        XCTAssertEqual(Describer.withoutPreamble("This screenshot displays the GitHub page for the Ollama project."),
                       "GitHub page for the Ollama project.")
        XCTAssertEqual(Describer.withoutPreamble("A webpage explaining Python's function definitions."),
                       "Explaining Python's function definitions.")
        XCTAssertEqual(Describer.withoutPreamble("An article defining volcanoes."), "An article defining volcanoes.")
        XCTAssertEqual(Describer.withoutPreamble("Pages from a 1920s cookbook."), "Pages from a 1920s cookbook.")
    }

    /// Real titles from the live session (2026-10-14).
    func testTheSiteNameLeavesTheTitle() {
        let wiki = "https://en.wikipedia.org/wiki/Matcha"
        XCTAssertEqual(Describer.withoutSiteName("Matcha - Wikipedia", url: wiki), "Matcha")
        XCTAssertEqual(Describer.withoutSiteName("Kyoto Wikipedia article", url: wiki), "Kyoto")
        XCTAssertEqual(Describer.withoutSiteName("Baguette Wikipedia", url: wiki), "Baguette")
        XCTAssertEqual(Describer.withoutSiteName("Apollo 11 Wikipedia article", url: wiki), "Apollo 11")
        XCTAssertEqual(Describer.withoutSiteName("Mona Lisa painting", url: wiki), "Mona Lisa painting")
        XCTAssertEqual(Describer.withoutSiteName("Wikipedia", url: wiki), "Wikipedia", "only the site: kept")
        XCTAssertEqual(Describer.withoutSiteName("Swift on GitHub", url: "https://github.com/apple/swift"), "Swift on GitHub",
                       "the site is part of the phrase")
        XCTAssertEqual(Describer.withoutSiteName("Hacker News Top Stories", url: "https://news.ycombinator.com/"), "Hacker News Top Stories")
        XCTAssertEqual(Describer.withoutSiteName("Refund payments | Stripe", url: "https://docs.stripe.com/refunds"), "Refund payments")
        XCTAssertEqual(Describer.withoutSiteName("Matcha - Wikipedia", url: nil), "Matcha - Wikipedia")
    }

    func testNotJSONIsAnError() {
        XCTAssertThrowsError(try Describer.parse("I can't see the image.", ocrText: "", url: nil, fallbackTitle: "x"))
    }

    func testLongFieldsAreCapped() throws {
        let long = String(repeating: "word ", count: 100)
        let d = try Describer.parse("{\"title\": \"\(long)\", \"summary\": \"\(long)\"}", ocrText: "", url: nil, fallbackTitle: "x")
        XCTAssertLessThanOrEqual(d.title.count, 90)
        XCTAssertLessThanOrEqual(d.summary.count, 400)
    }

    func testThePromptCarriesTheContextAndEveryKind() {
        let prompt = Describer.prompt(app: "Safari", windowTitle: "Starter", url: "https://x.com", ocrExcerpt: "hello")
        XCTAssertTrue(prompt.contains("App: Safari"))
        XCTAssertTrue(prompt.contains("URL: https://x.com"))
        for kind in CaptureKind.allCases { XCTAssertTrue(prompt.contains(kind.rawValue)) }
    }
}

final class OrganizerTests: XCTestCase {
    private func axis(_ i: Int, _ mix: (Int, Float)? = nil) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[i] = 1
        if let (j, w) = mix { v[j] = w }
        return VectorMath.unit(v)
    }

    func testJoinsTheClosestCollectionWhenCloseEnough() {
        let organizer = Organizer(joinThreshold: 0.75, formThreshold: 0.78)
        let decision = organizer.decide(vector: axis(0, (1, 0.3)),
                                        collections: [.init(id: "a", members: [axis(0), axis(0, (2, 0.2))]),
                                                      .init(id: "b", members: [axis(1)])], unsorted: [])
        guard case .join(let id, let similarity) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(id, "a")
        XCTAssertGreaterThan(similarity, 0.9)
    }

    /// A big, broad collection's centre is "like everything"; a capture near
    /// the centre but near no member does not join (the chain that pulled
    /// 14 of 16 unrelated pages into one collection).
    func testACentreAloneIsNotEnoughToJoin() {
        let organizer = Organizer(joinThreshold: 0.5, formThreshold: 0.9)
        let broad = Organizer.Group(id: "broad", members: [axis(0), axis(1), axis(2), axis(3)])
        // Equally like every member (0.5 each), so like the centre (1.0).
        let vector = VectorMath.unit([1, 1, 1, 1, 0, 0, 0, 0])
        XCTAssertGreaterThan(VectorMath.dot(vector, VectorMath.centroid(broad.members)!), 0.99)
        XCTAssertEqual(organizer.decide(vector: vector, collections: [broad], unsorted: []), .stayUnsorted)
    }

    func testFormsACollectionWithSimilarUnsortedCaptures() {
        let organizer = Organizer(joinThreshold: 0.75, formThreshold: 0.78)
        let decision = organizer.decide(vector: axis(2), collections: [.init(id: "a", members: [axis(0)])],
                                        unsorted: [("x", axis(2, (3, 0.2))), ("y", axis(5)), ("z", axis(2, (4, 0.4)))])
        XCTAssertEqual(decision.formedWith, ["x", "z"])
    }

    func testAloneItStaysUnsorted() {
        let organizer = Organizer()
        XCTAssertEqual(organizer.decide(vector: axis(6), collections: [.init(id: "a", members: [axis(0)])],
                                        unsorted: [("y", axis(5))]), .stayUnsorted)
    }

    func testCollectionsAreRenamedAsTheyDouble() {
        var c = CaptureCollection(name: "x", emoji: "📁", count: 2, namedAtCount: 0)
        XCTAssertTrue(Organizer.shouldRename(c))
        c.namedAtCount = 2; c.count = 3
        XCTAssertFalse(Organizer.shouldRename(c))
        c.count = 4
        XCTAssertTrue(Organizer.shouldRename(c))
        c.userNamed = true
        XCTAssertFalse(Organizer.shouldRename(c))
    }

    func testTheNamerAnswerIsChecked() {
        XCTAssertTrue(CollectionNamer.parse(#"{"name": "Sourdough Baking", "emoji": "🍞"}"#) == ("Sourdough Baking", "🍞"))
        let fallback = CollectionNamer.parse("no idea")
        XCTAssertEqual(fallback.name, "Untitled collection")
        XCTAssertEqual(fallback.emoji, "📁")
        XCTAssertEqual(CollectionNamer.parse(#"{"name": "Bread", "emoji": "bread"}"#).emoji, "📁")
        XCTAssertEqual(CollectionNamer.parse(#"{"name": "Japan", "emoji": "🇯🇵"}"#).emoji, "🇯🇵", "a flag")
        XCTAssertEqual(CollectionNamer.parse(#"{"name": "Hearts", "emoji": "❤️"}"#).emoji, "❤️", "text-default with FE0F")
        XCTAssertEqual(CollectionNamer.parse(#"{"name": "Code", "emoji": "💻 laptop"}"#).emoji, "💻")
    }
}

private extension Organizer.Decision {
    var formedWith: [String]? {
        if case .form(let ids, _) = self { return ids }
        return nil
    }
}

final class SearchAndModelsTests: XCTestCase {
    func testMergeRanksWhatSeveralFindFirst() {
        let ids = SearchMerge.merge([["a", "b"], ["b", "c"], []])
        XCTAssertEqual(ids.first, "b")
        XCTAssertEqual(Set(ids), ["a", "b", "c"])
    }

    /// Real scores for "space exploration" over 38 captures (the test Mac,
    /// 2026-10-14): by look only two stand out (Apollo 11 scored 0.642, under
    /// the 0.664 floor), by meaning three; the NASA collection, 3 of 4 found,
    /// brings Apollo 11 in.
    func testSpaceExplorationFindsEveryMission() {
        func scores(_ top: [(String, Float)], rest median: Float) -> [(id: String, score: Float)] {
            top.map { ($0.0, $0.1) } + (0..<30).map { ("other\($0)", median - Float($0) * 0.002) }
        }
        let look = SearchMerge.standouts(scores([("crs35", 0.673), ("perseverance", 0.668), ("apollo", 0.642),
                                                 ("iss", 0.633), ("espresso", 0.626)], rest: 0.6)).map(\.id)
        XCTAssertEqual(look, ["crs35", "perseverance"])
        let meaning = SearchMerge.standouts(scores([("perseverance", 0.716), ("crs35", 0.71), ("iss", 0.709),
                                                    ("ddg", 0.649), ("python", 0.646)], rest: 0.61)).map(\.id)
        XCTAssertEqual(meaning, ["perseverance", "crs35", "iss"])
        let found = SearchMerge.merge([look, meaning])
        let completed = SearchMerge.completingCollections(found, members: [
            "nasa": ["crs35", "iss", "apollo", "perseverance"], "coffee": ["espresso", "latte", "flat"],
        ])
        XCTAssertEqual(Set(completed), ["crs35", "perseverance", "iss", "apollo"])
        XCTAssertEqual(completed.last, "apollo", "completed members rank after what was found")
    }

    func testACollectionIsCompletedOnlyWhenMostlyFound() {
        let members = ["c": ["a", "b", "c", "d"], "pair": ["x", "y"]]
        XCTAssertEqual(SearchMerge.completingCollections(["a", "b"], members: members), ["a", "b"], "half is not enough")
        XCTAssertEqual(SearchMerge.completingCollections(["x"], members: members), ["x"], "too small to complete")
        XCTAssertTrue(SearchMerge.standouts([]).isEmpty)
    }

    func testVersions() {
        XCTAssertTrue(Models.isVersion("0.40.4", atLeast: "0.40.0"))
        XCTAssertTrue(Models.isVersion("0.41.0-rc1", atLeast: "0.40.0"))
        XCTAssertFalse(Models.isVersion("0.30.9", atLeast: "0.40.0"))
        XCTAssertEqual(Models.vision(ramGB: 24), "qwen3.5:4b")
        XCTAssertEqual(Models.vision(ramGB: 8), "qwen3.5:2b-q4_K_M")
    }

    func testTheEmbeddingTextFollowsEmbeddingGemmasFormat() {
        let capture = Capture(app: "Safari", windowTitle: "Starter", width: 10, height: 10,
                              ocrText: "Feed it every 12 hours", title: "Feeding a starter", summary: "How to feed it.",
                              tags: ["sourdough"])
        let text = EmbeddingText.document(capture)
        XCTAssertTrue(text.hasPrefix("title: Safari — Feeding a starter | text: How to feed it."), text)
        XCTAssertTrue(text.contains("sourdough") && text.contains("Feed it every 12 hours"))
        XCTAssertEqual(EmbeddingText.query("bread"), "task: search result | query: bread")
    }
}
