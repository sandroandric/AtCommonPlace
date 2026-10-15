import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a photo or video file into a capture: the picture the library
/// shows (a JPEG, at most `displayPixel` on the long side, upright), its
/// thumbnail, and for a video a contact sheet of key frames (what the
/// models look at).  The original file is copied into the library by
/// `Library.keepImported`.
public enum MediaImporter {
    public static let displayPixel = 2_560
    public static let sheetFrames = 6

    public enum Failure: Error, Equatable {
        case notMedia(String)
        case unreadable(String)
    }

    /// What an import becomes before it is kept.
    public struct Imported {
        public var capture: Capture
        public var image: Data
        public var thumbnail: Data
        /// A video's contact sheet.
        public var sheet: Data?
    }

    public static func kind(of url: URL) -> CaptureMedia? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .photo }
        return nil
    }

    public static func load(_ url: URL, now: Date = Date()) async throws -> Imported {
        switch kind(of: url) {
        case .photo: return try photo(url, now: now)
        case .video: return try await video(url, now: now)
        default: throw Failure.notMedia(url.lastPathComponent)
        }
    }

    // MARK: - Photos

    static func photo(_ url: URL, now: Date) throws -> Imported {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let display = scaled(source, maxPixel: displayPixel),
              let image = Thumbnailer.jpeg(display, quality: 0.88),
              let thumb = scaled(source, maxPixel: 720).flatMap({ Thumbnailer.jpeg($0, quality: 0.82) }) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let id = UUID().uuidString.lowercased()
        let capture = Capture(
            id: id, createdAt: now, app: "Photos", windowTitle: url.deletingPathExtension().lastPathComponent,
            width: display.width, height: display.height,
            media: .photo, takenAt: takenDate(properties), imageFile: "media/\(id).jpg",
            originalFile: "media/\(id)-original.\(url.pathExtension.lowercased())"
        )
        return Imported(capture: capture, image: image, thumbnail: thumb, sheet: nil)
    }

    /// Upright (EXIF orientation applied), at most `maxPixel` on the long side.
    static func scaled(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// EXIF DateTimeOriginal (local time of the camera), else TIFF DateTime.
    static func takenDate(_ properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    // MARK: - Videos

    static func video(_ url: URL, now: Date) async throws -> Imported {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.unreadable(url.lastPathComponent) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_280, height: 1_280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frames: [CGImage] = []
        for time in keyTimes(duration: duration, count: sheetFrames) {
            if let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                frames.append(frame)
            }
        }
        guard let poster = frames.first,
              let image = Thumbnailer.jpeg(poster, quality: 0.88),
              let thumb = Thumbnailer.jpeg(from: image, maxPixel: 720, quality: 0.82),
              let sheet = contactSheet(frames).flatMap({ Thumbnailer.jpeg($0, quality: 0.85) }) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let created = try? await asset.load(.creationDate)?.load(.dateValue)
        let id = UUID().uuidString.lowercased()
        let capture = Capture(
            id: id, createdAt: now, app: "Videos", windowTitle: url.deletingPathExtension().lastPathComponent,
            width: poster.width, height: poster.height,
            media: .video, duration: duration, takenAt: created ?? nil, imageFile: "media/\(id).jpg",
            originalFile: "media/\(id)-original.\(url.pathExtension.lowercased())"
        )
        return Imported(capture: capture, image: image, thumbnail: thumb, sheet: sheet)
    }

    /// `count` moments spread over the video, skipping the first and last
    /// 5% (fades, black frames).
    public static func keyTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0, count > 0 else { return [] }
        if count == 1 { return [duration / 2] }
        let start = duration * 0.05, end = duration * 0.95
        return (0..<count).map { start + (end - start) * Double($0) / Double(count - 1) }
    }

    /// The frames in a grid (3 across), each 640 px wide, in order.
    public static func contactSheet(_ frames: [CGImage]) -> CGImage? {
        guard let first = frames.first else { return nil }
        let columns = min(3, frames.count)
        let rows = Int((Double(frames.count) / Double(columns)).rounded(.up))
        let cellWidth = 640
        let cellHeight = max(1, Int(Double(cellWidth) * Double(first.height) / Double(max(first.width, 1))))
        let gap = 8
        let width = columns * cellWidth + (columns - 1) * gap
        let height = rows * cellHeight + (rows - 1) * gap
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, frame) in frames.enumerated() {
            let column = index % columns, row = index / columns
            // CGContext's origin is bottom-left: the first row is at the top.
            let y = height - (row + 1) * cellHeight - row * gap
            context.draw(frame, in: CGRect(x: column * (cellWidth + gap), y: y, width: cellWidth, height: cellHeight))
        }
        return context.makeImage()
    }
}
