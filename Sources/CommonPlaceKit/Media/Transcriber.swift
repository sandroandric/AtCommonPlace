import AVFoundation
import Foundation
import Speech

/// What is said in a video, by Apple's speech recognition on this Mac
/// (`requiresOnDeviceRecognition`: the audio never leaves it).  Nil when
/// speech recognition is not allowed, unavailable for the language, or
/// nothing is said.
public enum Transcriber {
    public static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Ask once (the app calls this before the first video).
    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    public static func transcribe(_ video: URL, locale: Locale = .current) async -> String? {
        guard isAuthorized else { return nil }
        let recognizer = SFSpeechRecognizer(locale: locale).flatMap { $0.supportsOnDeviceRecognition ? $0 : nil }
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable,
              let audio = await audioTrack(of: video) else { return nil }
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let once = Once()
        let text: String? = await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { continuation.resume(returning: nil) }
                }
            }
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The video's sound as a temporary .m4a; nil without an audio track.
    static func audioTrack(of video: URL) async -> URL? {
        let asset = AVURLAsset(url: video)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cp-audio-\(UUID().uuidString).m4a")
        do {
            try await export.export(to: out, as: .m4a)
            return out
        } catch {
            return nil
        }
    }

    /// Resumes a continuation once, whichever callback comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}
