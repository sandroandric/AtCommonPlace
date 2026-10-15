import AVFoundation
import CommonPlaceKit
import ScreenCaptureKit

/// Records part of a window, with its sound, to an MP4 (H.264 + AAC): a
/// video playing in a page, kept as it plays.  ScreenCaptureKit delivers
/// frames and audio on one queue; AVAssetWriter writes them as they come.
final class VideoRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maximumSeconds: Double = 60

    private let queue = DispatchQueue(label: "commonplace.video-recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var started = false
    private(set) var output: URL?
    /// The sound's loudness, 0 (silent, -50 dB and below) to 1 (0 dB).
    private let levelLock = NSLock()
    private var currentLevel: Float = 0

    var level: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return currentLevel
    }

    enum Failure: Error {
        case cannotWrite
    }

    /// Start recording `area` (points, relative to the window's top-left) of `window`.
    func start(window: SCWindow, area: CGRect, scale: CGFloat) async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cp-recording-\(UUID().uuidString).mp4")
        // Even pixel sizes: H.264 needs them.
        let width = max(2, Int(area.width * scale) / 2 * 2)
        let height = max(2, Int(area.height * scale) / 2 * 2)

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw Failure.cannotWrite }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? Failure.cannotWrite }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = false
        configuration.queueDepth = 6
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        queue.sync {
            self.writer = writer
            self.video = video
            self.audio = audio
            self.started = false
            self.output = out
        }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Stop and finish the file; nil when nothing was recorded.
    func stop() async -> URL? {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let (writer, video, audio, started, output) = queue.sync { (self.writer, self.video, self.audio, self.started, self.output) }
        guard let writer, started else {
            writer?.cancelWriting()
            return nil
        }
        video?.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? output : nil
    }

    // MARK: - SCStreamOutput (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            // Only complete frames carry a picture (idle and blank ones do not).
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                writer.startSession(atSourceTime: sample.presentationTimeStamp)
                started = true
            }
            if let video, video.isReadyForMoreMediaData { video.append(sample) }
        case .audio:
            measure(sample)
            if started, let audio, audio.isReadyForMoreMediaData { audio.append(sample) }
        default:
            break
        }
    }

    /// The buffer's loudness (RMS of its first channel; ScreenCaptureKit
    /// delivers 32-bit float samples).
    private func measure(_ sample: CMSampleBuffer) {
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
              let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        let value = max(0, min(1, (decibels + 50) / 50))
        levelLock.lock()
        currentLevel = value
        levelLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("CommonPlace: recording stopped: \(error.localizedDescription)")
    }
}
