import XCTest
@testable import CommonPlaceKit

final class CheckInTests: XCTestCase {
    func testDueOncePerDayAndAfterAClockChange() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(CheckIn.isDue(last: nil, now: now))
        XCTAssertFalse(CheckIn.isDue(last: now.addingTimeInterval(-3_600), now: now))
        XCTAssertFalse(CheckIn.isDue(last: now.addingTimeInterval(-19.9 * 3_600), now: now))
        XCTAssertTrue(CheckIn.isDue(last: now.addingTimeInterval(-20 * 3_600), now: now))
        XCTAssertTrue(CheckIn.isDue(last: now.addingTimeInterval(86_400 * 3), now: now))
    }

    func testPayloadIsNumbersOnly() {
        let id = UUID(uuidString: "3F6C2B8E-1D4A-4C9B-9E2F-5A7D8C1B2E3F")!
        let p = CheckIn.payload(id: id, appVersion: "0.1.1", os: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1), kept: 12)
        XCTAssertEqual(p, CheckInPayload(id: "3f6c2b8e-1d4a-4c9b-9e2f-5a7d8c1b2e3f", version: "0.1.1", os: "15.6.1", kept: 12))
        XCTAssertEqual(CheckIn.payload(id: id, appVersion: "0.1.1 (beta)", os: OperatingSystemVersion(), kept: -3).kept, 0)
        XCTAssertEqual(CheckIn.payload(id: id, appVersion: "0.2", os: OperatingSystemVersion(), kept: 99_999).kept, 10_000)
        XCTAssertEqual(CheckIn.payload(id: id, appVersion: "", os: OperatingSystemVersion(), kept: 0).version, "0.0")
    }

    /// The JSON is exactly the four fields the server accepts, and the
    /// server's ID rule matches a v4 UUID as the app makes it.
    func testRequestCarriesOnlyTheFourFields() throws {
        let p = CheckIn.payload(id: UUID(), appVersion: "0.1.1", os: ProcessInfo.processInfo.operatingSystemVersion, kept: 3)
        let request = try CheckIn.request(p)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://atcommonplace.com/api/checkin")
        XCTAssertFalse(request.httpShouldHandleCookies)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "version", "os", "kept"])
        let server = try NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        XCTAssertEqual(server.numberOfMatches(in: p.id, range: NSRange(p.id.startIndex..., in: p.id)), 1)
    }
}
