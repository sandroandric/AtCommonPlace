import AppKit
import CommonPlaceKit
import SwiftUI

/// What the library window shows: a shelf of captures.
enum Shelf: Hashable {
    case recent, favorites, unsorted
    case collection(String)
    case kind(CaptureKind)
    case source(String)

    var filter: LibraryFilter {
        switch self {
        case .recent: return .recent
        case .favorites: return .favorites
        case .unsorted: return .unsorted
        case .collection(let id): return .collection(id)
        case .kind(let kind): return .kind(kind)
        case .source(let source): return .source(source)
        }
    }
}

/// The app's state on the main actor: the shelves, the captures shown, the
/// search, the selection, and whether Ollama and its models are ready.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let library: Library
    /// The UI's own connection, for reading (the library's actor writes with its own).
    let store: LibraryStore
    let client = OllamaClient()

    @Published var shelf: Shelf = .recent { didSet { if shelf != oldValue { mediaFilter = nil; reload() } } }
    @Published var query = "" { didSet { searchSoon() } }
    /// Screens, photos or videos only (the tabs over the wall); nil for all.
    @Published var mediaFilter: CaptureMedia?
    /// Kept since the start of today, this week or this month; nil for any time.
    @Published var timeFilter: TimeShelf?
    @Published private(set) var captures: [Capture] = []
    @Published private(set) var findings: SearchFindings?
    /// How long the last search took, in milliseconds.
    @Published private(set) var searchMilliseconds = 0
    @Published private(set) var searching = false
    /// Up to three members of each collection, newest first (its covers).
    @Published private(set) var covers: [String: [Capture]] = [:]
    @Published private(set) var collections: [CaptureCollection] = []
    @Published private(set) var kinds: [(CaptureKind, Int)] = []
    @Published private(set) var sources: [(String, Int)] = []
    @Published private(set) var total = 0
    /// The last four things kept, on any shelf, newest first.
    @Published private(set) var latest: [Capture] = []
    var newest: Capture? { latest.first }
    @Published private(set) var favoritesCount = 0
    @Published private(set) var unsortedCount = 0
    @Published private(set) var timeCounts: [TimeShelf: Int] = [:]
    @Published private(set) var mediaCounts: [CaptureMedia: Int] = [:]
    /// Files are being dragged over the library.
    @Published var dropTargeted = false
    /// Imports under way (files being read).
    @Published private(set) var importing = 0
    @Published private(set) var understanding = 0
    @Published var selectedID: String?
    @Published private(set) var lastKept: Capture?
    @Published private(set) var setup = SetupState()

    private var searchTask: Task<Void, Never>?

    nonisolated static let visionModelDefault = "visionModel"

    /// The vision model (Settings), else the one for this Mac's memory.
    nonisolated static var visionModel: String {
        UserDefaults.standard.string(forKey: visionModelDefault) ?? Models.vision()
    }

    func setVisionModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: Self.visionModelDefault)
        Task { await library.setVisionModel(model) }
    }

    private init() {
        do {
            library = Library(store: try LibraryStore(root: LibraryStore.defaultRoot), visionModel: Self.visionModel)
            store = try LibraryStore(root: LibraryStore.defaultRoot)
        } catch {
            fatalError("CommonPlace cannot open its library at \(LibraryStore.defaultRoot.path): \(error)")
        }
        Task {
            await library.setOnChange { [weak self] in self?.reload() }
            reload()
            await library.work()
        }
    }

    /// What the wall shows: the search's results while searching, else the
    /// shelf, narrowed by the media tab and the time.
    var shown: [Capture] {
        if let findings { return findings.hits.map(\.capture) }
        return captures.filter { capture in
            (mediaFilter == nil || capture.media == mediaFilter)
                && (timeFilter.map { capture.createdAt >= $0.start() } ?? true)
        }
    }

    /// The shelf's counts per media, for the tabs (before the media filter).
    var shelfMediaCounts: [CaptureMedia: Int] {
        Dictionary(grouping: captures.filter { capture in timeFilter.map { capture.createdAt >= $0.start() } ?? true }, by: \.media)
            .mapValues(\.count)
    }

    var searchingNow: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var selected: Capture? {
        guard let selectedID else { return nil }
        return shown.first { $0.id == selectedID } ?? (try? store.capture(selectedID)) ?? nil
    }

    func collection(_ id: String?) -> CaptureCollection? {
        guard let id else { return nil }
        return collections.first { $0.id == id }
    }

    var shelfTitle: String {
        switch shelf {
        case .recent: return "Home"
        case .favorites: return "Favorites"
        case .unsorted: return "Unsorted"
        case .collection(let id): return collection(id)?.name ?? "Collection"
        case .kind(let kind): return kind.title
        case .source(let source): return source
        }
    }

    // MARK: - Loading

    func reload() {
        captures = (try? store.captures(shelf.filter)) ?? []
        collections = ((try? store.collections()) ?? []).filter { $0.count > 0 }
        kinds = (try? store.kindCounts()) ?? []
        sources = (try? store.sourceCounts()) ?? []
        total = (try? store.count()) ?? 0
        latest = (try? store.captures(.recent, limit: 4)) ?? []
        favoritesCount = ((try? store.captures(.favorites, limit: 100_000)) ?? []).count
        unsortedCount = ((try? store.captures(.unsorted, limit: 100_000)) ?? []).count
        mediaCounts = (try? store.mediaCounts()) ?? [:]
        timeCounts = Dictionary(uniqueKeysWithValues: TimeShelf.allCases.map { ($0, (try? store.count(since: $0.start())) ?? 0) })
        understanding = ((try? store.pending(now: .distantFuture, limit: 10_000)) ?? []).count
        covers = Dictionary(uniqueKeysWithValues: collections.map { collection in
            (collection.id, (try? store.captures(.collection(collection.id), limit: 3)) ?? [])
        })
        if let lastKept, let fresh = try? store.capture(lastKept.id) { self.lastKept = fresh }
        if !query.isEmpty { searchSoon(delay: 0) }
    }

    private func searchSoon(delay: UInt64 = 250_000_000) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            findings = nil
            searching = false
            return
        }
        searching = true
        searchTask = Task { [library] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            let start = Date()
            let found = await library.findings(text)
            guard !Task.isCancelled else { return }
            self.searchMilliseconds = Int(Date().timeIntervalSince(start) * 1_000)
            self.findings = found
            self.searching = false
        }
    }

    // MARK: - Capturing

    /// The video being recorded, and where it plays (for its page context).
    private var recorder: VideoRecorder?
    private var recordingTarget: WindowCapturer.Target?
    private var recordingLimit: Task<Void, Never>?

    /// The gesture fired: keep what the user is looking at.  In a browser,
    /// the image under the pointer is kept as a photo and a video under it
    /// is recorded (the keys again stop it); anything else keeps the window.
    func captureNow() {
        Task {
            if recorder != nil {
                await finishRecording()
                return
            }
            // The keys pressed in CommonPlace's own window: it never keeps itself.
            if LibraryWindow.isFrontmost {
                CaptureFeedback.shared.showSelf()
                return
            }
            do {
                let target = try await WindowCapturer.focusedTarget()
                let app = NSRunningApplication(processIdentifier: pid_t(target.entry.pid))
                let onPage = app != nil ? await PagePointer.target(in: app!) : .window
                switch onPage {
                case .image(let source, let frame):
                    try await keepPagePhoto(target, source: source, frame: frame)
                case .video(let frame):
                    try await startRecording(target, frame: frame)
                case .window:
                    let shot = try await WindowCapturer.shot(of: target)
                    try await library.keep(shot.capture, png: shot.png, thumbnail: shot.thumbnail)
                    lastKept = shot.capture
                    CaptureFeedback.shared.show(shot)
                    NotificationCenter.default.post(name: .commonPlaceKept, object: nil)
                }
            } catch WindowCapturer.Failure.noPermission {
                CaptureFeedback.shared.showProblem("CommonPlace needs Screen Recording to keep a window.",
                                                   action: "Open Setup") { SetupWindow.show() }
            } catch WindowCapturer.Failure.noWindow {
                CaptureFeedback.shared.showProblem("No window to keep here.", action: nil, perform: nil)
            } catch {
                CaptureFeedback.shared.showProblem("Couldn't keep this window: \(error.localizedDescription)",
                                                   action: nil, perform: nil)
            }
        }
    }

    // MARK: - Photos and videos inside a page

    /// The image under the pointer, as a photo of its page: downloaded from
    /// its address when that has more pixels than the screen shows, else
    /// cropped from the window at full resolution.
    private func keepPagePhoto(_ target: WindowCapturer.Target, source: URL?, frame: CGRect) async throws {
        let window = try await WindowCapturer.shoot(target)
        let crop = CGRect(x: (frame.minX - target.frame.minX) * target.scale, y: (frame.minY - target.frame.minY) * target.scale,
                          width: frame.width * target.scale, height: frame.height * target.scale)
            .intersection(CGRect(x: 0, y: 0, width: window.width, height: window.height)).integral
        let cropped = crop.isEmpty ? nil : window.cropping(to: crop)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var file: URL?
        var downloaded: (URL, Data, Int)?
        for candidate in source.map(ImageSources.candidates) ?? [] {
            if let (data, width) = await Self.download(image: candidate) {
                downloaded = (candidate, data, width)
                break
            }
        }
        if let (source, data, width) = downloaded, width >= (cropped?.width ?? 0) {
            let name = source.lastPathComponent.isEmpty ? "image" : source.deletingPathExtension().lastPathComponent
            let ext = MediaImporter.kind(of: source) == .photo ? source.pathExtension : "jpg"
            file = dir.appendingPathComponent("\(name).\(ext.isEmpty ? "jpg" : ext)")
            try data.write(to: file!)
        } else if let cropped, let png = Thumbnailer.png(cropped) {
            file = dir.appendingPathComponent("\(target.capture.windowTitle.isEmpty ? "image" : "image from page").png")
            try png.write(to: file!)
        }
        guard let file else { throw WindowCapturer.Failure.captureFailed }
        var imported = try await MediaImporter.load(file)
        Self.fromPage(&imported.capture, target)
        try await library.keepImported(imported, original: file)
        lastKept = imported.capture
        CaptureFeedback.shared.showKept(imported.capture, image: NSImage(data: imported.image) ?? NSImage(),
                                        over: frame, heading: "Kept · the photo")
        NotificationCenter.default.post(name: .commonPlaceKept, object: nil)
    }

    /// An image's bytes and pixel width, when the address answers with an
    /// image of at most 40 MB within 10 s.
    nonisolated static func download(image url: URL) async -> (Data, Int)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("CommonPlace/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.mimeType ?? "").hasPrefix("image/"), data.count < 40_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int else { return nil }
        return (data, width)
    }

    /// A photo or video kept from a page carries the page: its app, title and address.
    static func fromPage(_ capture: inout Capture, _ target: WindowCapturer.Target) {
        capture.app = target.capture.app
        capture.bundleID = target.capture.bundleID
        capture.url = target.capture.url
        capture.windowTitle = target.capture.windowTitle
    }

    private func startRecording(_ target: WindowCapturer.Target, frame: CGRect) async throws {
        if !Transcriber.isAuthorized { _ = await Transcriber.requestAuthorization() }
        let area = CGRect(x: frame.minX - target.frame.minX, y: frame.minY - target.frame.minY, width: frame.width, height: frame.height)
            .intersection(CGRect(origin: .zero, size: target.frame.size))
        let recorder = VideoRecorder()
        try await recorder.start(window: target.window, area: area.isEmpty ? CGRect(origin: .zero, size: target.frame.size) : area,
                                 scale: target.scale)
        self.recorder = recorder
        recordingTarget = target
        CaptureFeedback.shared.showRecording(over: frame) { [recorder] in recorder.level }
        recordingLimit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VideoRecorder.maximumSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finishRecording()
        }
    }

    /// Stop the recording and keep it as a video of its page.
    private func finishRecording() async {
        recordingLimit?.cancel()
        guard let recorder, let target = recordingTarget else { return }
        self.recorder = nil
        recordingTarget = nil
        guard let file = await recorder.stop() else {
            CaptureFeedback.shared.showProblem("Nothing was recorded: is the video playing?", action: nil, perform: nil)
            return
        }
        do {
            var imported = try await MediaImporter.load(file)
            Self.fromPage(&imported.capture, target)
            try await library.keepImported(imported, original: file)
            try? FileManager.default.removeItem(at: file)
            lastKept = imported.capture
            CaptureFeedback.shared.showKept(imported.capture, image: NSImage(data: imported.image) ?? NSImage(),
                                            over: nil, heading: "Kept · the video")
            NotificationCenter.default.post(name: .commonPlaceKept, object: nil)
        } catch {
            CaptureFeedback.shared.showProblem("Couldn't keep the recording: \(error.localizedDescription)", action: nil, perform: nil)
        }
    }

    // MARK: - Importing

    /// Add photos and videos: each is read (`MediaImporter`), copied into
    /// the library and understood like a kept window.  Speech recognition is
    /// asked for once, before the first video.
    func importFiles(_ urls: [URL]) {
        let media = urls.filter { MediaImporter.kind(of: $0) != nil }
        guard !media.isEmpty else {
            CaptureFeedback.shared.showProblem("CommonPlace takes photos and videos.", action: nil, perform: nil)
            return
        }
        importing += media.count
        Task {
            if media.contains(where: { MediaImporter.kind(of: $0) == .video }), !Transcriber.isAuthorized {
                _ = await Transcriber.requestAuthorization()
            }
            var added = 0
            var failed: [String] = []
            for url in media {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let imported = try await MediaImporter.load(url)
                    try await library.keepImported(imported, original: url)
                    added += 1
                } catch {
                    failed.append(url.lastPathComponent)
                }
                importing -= 1
            }
            if !failed.isEmpty {
                CaptureFeedback.shared.showProblem("Couldn't read \(failed.joined(separator: ", ")).", action: nil, perform: nil)
            } else if added > 0 {
                shelf = .recent
            }
        }
    }

    // MARK: - Editing

    func setNote(_ id: String, _ note: String) { Task { await library.setNote(id, note) } }
    func toggleFavorite(_ capture: Capture) { Task { await library.setFavorite(capture.id, !capture.favorite) } }
    func setTags(_ id: String, _ tags: [String]) { Task { await library.setTags(id, tags) } }
    func move(_ id: String, to collectionID: String?) { Task { await library.move(id, to: collectionID) } }
    func renameCollection(_ id: String, name: String, emoji: String) {
        Task { await library.renameCollection(id, name: name, emoji: emoji) }
    }
    func delete(_ id: String) {
        if selectedID == id { selectedID = nil }
        Task { await library.delete(id) }
    }
    func related(to id: String) async -> [Capture] { await library.related(to: id) }

    /// Open the capture before or after the one open, in the wall's order.
    func step(_ offset: Int) {
        let list = shown
        guard let id = selectedID, let index = list.firstIndex(where: { $0.id == id }) else { return }
        let next = index + offset
        guard list.indices.contains(next) else { return }
        selectedID = list[next].id
    }

    func image(for capture: Capture, full: Bool = false) -> NSImage? {
        let url = full ? store.imageURL(for: capture) : store.thumbURL(capture.id)
        return ThumbnailCache.shared.image(at: url)
    }

    func imageURL(_ capture: Capture) -> URL { store.imageURL(for: capture) }

    /// The capture's full picture on the clipboard; false when it could not be read.
    @discardableResult
    func copyImage(_ capture: Capture) -> Bool {
        guard let image = NSImage(contentsOf: imageURL(capture)) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
    }
    func originalURL(_ capture: Capture) -> URL? { store.originalURL(for: capture) }

    // MARK: - Setup

    func refreshSetup() async {
        setup = await SetupState.check(client: client)
    }
}

/// Decoded images, kept while the app runs (thumbnails are small).
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [URL: NSImage] = [:]

    func image(at url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[url] = image
        return image
    }

    func forget(_ url: URL) { images[url] = nil }
}
