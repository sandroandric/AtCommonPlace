import AppKit
import CommonPlaceKit

/// Sends the daily check-in (`CheckIn`) while it is on: a little after
/// launch, then whenever a day has passed (looked at every three hours).
/// Off in Settings means nothing is sent, ever.
@MainActor
final class CheckInService {
    static let shared = CheckInService()

    static let enabledKey = "checkInEnabled"
    private static let idKey = "checkInID"
    private static let lastKey = "checkInLast"

    private var timer: Timer?
    private var sending = false

    /// On unless turned off in Settings.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.sendIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3_600, repeats: true) { _ in
            MainActor.assumeIsolated { CheckInService.shared.sendIfDue() }
        }
    }

    func sendIfDue() {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastKey) as? Date
        guard Self.enabled, !sending, CheckIn.isDue(last: last) else { return }
        // The ID is random and made here; it identifies an install, not a person or a Mac.
        let id = defaults.string(forKey: Self.idKey).flatMap(UUID.init(uuidString:)) ?? {
            let id = UUID()
            defaults.set(id.uuidString, forKey: Self.idKey)
            return id
        }()
        // Kept since the last check-in (the first one: the last day).
        let since = last ?? Date().addingTimeInterval(-86_400)
        let kept = (try? AppModel.shared.store.count(since: since)) ?? 0
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let payload = CheckIn.payload(id: id, appVersion: version, os: ProcessInfo.processInfo.operatingSystemVersion, kept: kept)
        guard let request = try? CheckIn.request(payload) else { return }
        sending = true
        Task {
            let ok = await Self.send(request)
            sending = false
            if ok { defaults.set(Date(), forKey: Self.lastKey) }
        }
    }

    /// True when the server took it (2xx).  Failures are retried at the next look.
    nonisolated private static func send(_ request: URLRequest) async -> Bool {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
