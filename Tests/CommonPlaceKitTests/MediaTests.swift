import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CommonPlaceKit

final class MediaTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func solid(_ width: Int, _ height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testAPhotoIsUprightWithItsTakenDate() async throws {
        // 400 × 300 stored, EXIF orientation 6 (rotate 90°): shown 300 × 400.
        let url = dir.appendingPathComponent("IMG_0001.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, solid(400, 300, red: 0.8, green: 0.4, blue: 0.2), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:07:04 18:30:00"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let imported = try await MediaImporter.load(url, now: Date(timeIntervalSince1970: 2_000_000_000))
        let c = imported.capture
        XCTAssertEqual(c.media, .photo)
        XCTAssertEqual(c.width, 300)
        XCTAssertEqual(c.height, 400)
        XCTAssertEqual(c.windowTitle, "IMG_0001")
        XCTAssertEqual(c.imageFile, "media/\(c.id).jpg")
        XCTAssertEqual(c.originalFile, "media/\(c.id)-original.jpg")
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(c.takenAt))
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 7, 4, 18, 30])
        XCTAssertNil(imported.sheet)
        XCTAssertEqual(c.sourceName, "Photos")
    }

    /// A 4-second video, a different colour each second.
    private func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
        for frame in 0..<(4 * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 320, height: 180, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            let (r, g, b) = colors[frame / 10]
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    func testAVideoBecomesAPosterAndAContactSheet() async throws {
        let url = dir.appendingPathComponent("trip.mov")
        try await makeVideo(url)
        let imported = try await MediaImporter.load(url)
        let c = imported.capture
        XCTAssertEqual(c.media, .video)
        XCTAssertEqual(try XCTUnwrap(c.duration), 4, accuracy: 0.2)
        XCTAssertEqual([c.width, c.height], [320, 180], "the poster frame")
        XCTAssertEqual(c.originalFile, "media/\(c.id)-original.mov")
        let sheetData = try XCTUnwrap(imported.sheet)
        let sheet = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(sheetData as CFData, nil)!, 0, nil)!
        // Six frames, 3 across, 640 px each with 8 px gaps; 2 rows of 360.
        XCTAssertEqual(sheet.width, 3 * 640 + 2 * 8)
        XCTAssertEqual(sheet.height, 2 * 360 + 8)
    }

    func testKeyTimesSkipTheEnds() {
        XCTAssertEqual(MediaImporter.keyTimes(duration: 100, count: 6), [5, 23, 41, 59, 77, 95])
        XCTAssertEqual(MediaImporter.keyTimes(duration: 10, count: 1), [5])
        XCTAssertEqual(MediaImporter.keyTimes(duration: 0, count: 6), [])
        XCTAssertNil(MediaImporter.kind(of: URL(fileURLWithPath: "/x/notes.txt")))
        XCTAssertEqual(MediaImporter.kind(of: URL(fileURLWithPath: "/x/IMG.HEIC")), .photo)
        XCTAssertEqual(MediaImporter.kind(of: URL(fileURLWithPath: "/x/clip.mp4")), .video)
    }

    func testImportsAreKeptWithTheirOriginalAndMediaShelves() async throws {
        let root = dir.appendingPathComponent("library")
        let store = try LibraryStore(root: root)
        let library = Library(store: store, client: OllamaClient(host: URL(string: "http://127.0.0.1:9")!))
        let url = dir.appendingPathComponent("trip.mov")
        try await makeVideo(url)
        let imported = try await MediaImporter.load(url)
        try await library.keepImported(imported, original: url)
        let kept = try XCTUnwrap(try store.capture(imported.capture.id))
        XCTAssertEqual(kept.media, .video)
        XCTAssertEqual(try XCTUnwrap(kept.duration), 4, accuracy: 0.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.originalURL(for: kept)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sheetURL(kept.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(for: kept).path))
        XCTAssertEqual(try store.captures(.media(.video)).map(\.id), [kept.id])
        XCTAssertEqual(try store.mediaCounts(), [.video: 1])
        XCTAssertEqual(try store.sourceCounts().count, 0, "imports are not sources")
        try store.delete(kept.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.originalURL(for: kept)!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sheetURL(kept.id).path))
    }

    func testTheVideoPromptCarriesWhatIsSaidAndTheFrames() {
        let context = Describer.Context(media: .video, app: "Videos", windowTitle: "trip", duration: 42.4,
                                        transcript: "Welcome to the Kyoto bamboo forest.")
        let prompt = Describer.prompt(context, ocrExcerpt: "(none)")
        XCTAssertTrue(prompt.contains("This is a video (file \"trip\") 42 seconds long."), prompt)
        XCTAssertTrue(prompt.contains("key frames in order"))
        XCTAssertTrue(prompt.contains("Welcome to the Kyoto bamboo forest."))
        let photo = Describer.prompt(Describer.Context(media: .photo, app: "Photos", windowTitle: "IMG_2"), ocrExcerpt: "")
        XCTAssertTrue(photo.contains("This is a photo"), photo)
    }

    func testAVideosHighlightMayQuoteWhatIsSaid() throws {
        let answer = #"{"title": "Kyoto bamboo walk", "summary": "A walk.", "kind": "place", "tags": ["kyoto"], "highlights": ["Welcome to the Kyoto bamboo forest."]}"#
        let d = try Describer.parse(answer, ocrText: "\nWelcome to the Kyoto bamboo forest.", url: nil, fallbackTitle: "trip")
        XCTAssertEqual(d.highlights, ["Welcome to the Kyoto bamboo forest."])
    }

    func testAnOldLibraryGainsTheMediaColumns() throws {
        // A version 1 library (before photos and videos) opens and migrates.
        let root = dir.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try Database(path: root.appendingPathComponent("library.sqlite").path)
        try db.execute("""
            CREATE TABLE captures (id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, app TEXT NOT NULL DEFAULT '',
                bundle_id TEXT, window_title TEXT NOT NULL DEFAULT '', url TEXT, document_path TEXT,
                source TEXT NOT NULL DEFAULT '', width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0,
                stage TEXT NOT NULL DEFAULT 'captured', ocr_text TEXT, title TEXT, summary TEXT, kind TEXT,
                highlights TEXT NOT NULL DEFAULT '[]', links TEXT NOT NULL DEFAULT '[]', note TEXT,
                favorite INTEGER NOT NULL DEFAULT 0, collection_id TEXT, attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at REAL NOT NULL DEFAULT 0, last_error TEXT);
            CREATE TABLE capture_tags (capture_id TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY (capture_id, tag));
            CREATE TABLE collections (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, emoji TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL, updated_at REAL NOT NULL, named_at_count INTEGER NOT NULL DEFAULT 0,
                user_named INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE vectors (capture_id TEXT NOT NULL, space TEXT NOT NULL, model TEXT NOT NULL, dim INTEGER NOT NULL,
                vector BLOB NOT NULL, PRIMARY KEY (capture_id, space));
            CREATE VIRTUAL TABLE captures_fts USING fts5(id UNINDEXED, title, summary, ocr, note, tags, source);
            INSERT INTO captures (id, created_at, app, window_title, stage) VALUES ('old', 1, 'Safari', 'Espresso', 'organized');
            PRAGMA user_version = 1;
            """)
        let store = try LibraryStore(root: root)
        let old = try XCTUnwrap(try store.capture("old"))
        XCTAssertEqual(old.media, .screen)
        XCTAssertEqual(store.imageURL(for: old), store.imageURL("old"))
    }
}
