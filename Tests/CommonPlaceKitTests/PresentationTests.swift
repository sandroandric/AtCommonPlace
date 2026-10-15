import CoreGraphics
import XCTest
@testable import CommonPlaceKit

final class PresentationTests: XCTestCase {
    func testCountsAreSpelledBelowAHundred() {
        XCTAssertEqual(Wording.count(12, "thing", "things"), "Twelve things")
        XCTAssertEqual(Wording.count(1, "thing", "things"), "One thing")
        XCTAssertEqual(Wording.count(42, "thing", "things", capitalized: false), "forty-two things")
        XCTAssertEqual(Wording.count(143, "thing", "things"), "143 things")
    }

    func testTodayHeadline() {
        XCTAssertEqual(Wording.today(kept: 12, hour: 9).lead, "Twelve things,")
        XCTAssertEqual(Wording.today(kept: 12, hour: 9).close, "kept today.")
        XCTAssertEqual(Wording.today(kept: 0, hour: 9).lead, "Nothing kept")
        XCTAssertEqual(Wording.today(kept: 0, hour: 21).close, "nothing kept.")
    }

    func testSearchHeadline() {
        XCTAssertEqual(Wording.search(found: 4), "Four things about")
        XCTAssertEqual(Wording.search(found: 1), "One thing about")
        XCTAssertEqual(Wording.search(found: 0), "Nothing yet about")
    }

    func testMilestones() {
        XCTAssertEqual(Wording.milestone(total: 1), "Your first thing kept.")
        XCTAssertEqual(Wording.milestone(total: 10), "Ten things kept.")
        XCTAssertEqual(Wording.milestone(total: 200), "200 things kept.")
        XCTAssertNil(Wording.milestone(total: 0))
        XCTAssertNil(Wording.milestone(total: 49))
    }

    func testSkyPhases() {
        XCTAssertEqual(SkyPhase.at(hour: 3), .night)
        XCTAssertEqual(SkyPhase.at(hour: 6, minute: 30), .dawn)
        XCTAssertEqual(SkyPhase.at(hour: 8), .morning)
        XCTAssertEqual(SkyPhase.at(hour: 13), .day)
        XCTAssertEqual(SkyPhase.at(hour: 18, minute: 15), .golden)
        XCTAssertEqual(SkyPhase.at(hour: 20), .dusk)
        XCTAssertEqual(SkyPhase.at(hour: 23), .night)
    }

    func testContactSheetCellsMatchTheImportersGrid() {
        // Six 640 × 360 frames, three across, 8 px apart: 1936 × 728.
        let cells = ContactSheet.cells(width: 1936, height: 728)
        XCTAssertEqual(cells?.count, 6)
        XCTAssertEqual(cells?[0], CGRect(x: 0, y: 0, width: 640, height: 360))
        XCTAssertEqual(cells?[4], CGRect(x: 648, y: 368, width: 640, height: 360))
        XCTAssertNil(ContactSheet.cells(width: 1000, height: 728))
        XCTAssertNil(ContactSheet.cells(width: 1936, height: 729))
    }

    func testTheSheetTheImporterDrawsIsCutBackExactly() throws {
        let frame = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let sheet = try XCTUnwrap(MediaImporter.contactSheet(Array(repeating: frame, count: MediaImporter.sheetFrames)))
        XCTAssertEqual(ContactSheet.cells(width: sheet.width, height: sheet.height)?.count, MediaImporter.sheetFrames)
    }

    func testSearchReasons() {
        let reasons = SearchMerge.reasons([.words: ["a"], .look: ["a", "b"], .meaning: ["c"]], completed: ["a", "b", "c", "d"])
        XCTAssertEqual(reasons["a"], [.words, .look])
        XCTAssertEqual(reasons["b"], [.look])
        XCTAssertEqual(reasons["c"], [.meaning])
        XCTAssertEqual(reasons["d"], [.collection])
    }

    func testCoveredCollections() {
        let members = ["nasa": ["r", "a", "o", "s"], "food": ["e", "c", "m"]]
        XCTAssertEqual(SearchMerge.coveredCollections(["r", "o", "s"], members: members), ["nasa"])
        XCTAssertEqual(SearchMerge.coveredCollections(["r", "e"], members: members), [])
    }
}
