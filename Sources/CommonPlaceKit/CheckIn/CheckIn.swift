import Foundation

/// The app's daily check-in: how many Macs use CommonPlace, nothing about
/// what they keep.  A random install ID (never tied to a person or a
/// machine), the app and macOS versions, and how many things were kept
/// since the last check-in, as a number.  Sent once a day while it is on
/// (Settings); the server counts the ID only in HyperLogLogs, which give
/// unique counts and cannot be read back.
public struct CheckInPayload: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let os: String
    public let kept: Int

    public init(id: String, version: String, os: String, kept: Int) {
        self.id = id
        self.version = version
        self.os = os
        self.kept = kept
    }
}

public enum CheckIn {
    public static let endpoint = URL(string: "https://atcommonplace.com/api/checkin")!

    /// Due when there has been none, or the last was 20 hours ago or more:
    /// a little under a day, so a Mac opened at the same time each morning
    /// checks in every day.
    public static let minimumInterval: TimeInterval = 20 * 3_600

    public static func isDue(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        // A clock set back counts as due rather than silent for days.
        return now.timeIntervalSince(last) >= minimumInterval || last > now
    }

    /// The payload, with the count kept in the range the server accepts and
    /// versions reduced to their numbers ("15.6.1", "0.1.1").
    public static func payload(id: UUID, appVersion: String, os: OperatingSystemVersion, kept: Int) -> CheckInPayload {
        let version = appVersion.split(separator: ".").prefix(3).compactMap { Int($0) }.map(String.init).joined(separator: ".")
        return CheckInPayload(id: id.uuidString.lowercased(),
                              version: version.isEmpty ? "0.0" : version,
                              os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                              kept: min(max(kept, 0), 10_000))
    }

    /// The POST for `payload`: JSON, no cookies, a short timeout.
    public static func request(_ payload: CheckInPayload, to endpoint: URL = endpoint) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }
}
