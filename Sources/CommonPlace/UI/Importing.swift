import AppKit
import CommonPlaceKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The library's ways in for photos and videos: Import… (files), From
/// Photos… (the system picker: no Photos permission needed), and drops.
struct ImportButtons: View {
    @ObservedObject private var model = AppModel.shared
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
            Text("From Photos")
        }
        .buttonStyle(GhostButton())
        .help("Add photos and videos from your Photos library")
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                var urls: [URL] = []
                for item in items {
                    if let file = try? await item.loadTransferable(type: PickedFile.self) { urls.append(file.url) }
                }
                model.importFiles(urls)
            }
        }

        Button {
            ImportPanel.run()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .semibold))
                Text("Import")
            }
        }
        .buttonStyle(InkButton())
        .help("Add photos and videos from files (⇧⌘I)")
    }
}

/// Import…: choose photos and videos from files.
@MainActor
enum ImportPanel {
    static func run() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "Add to CommonPlace"
        if panel.runModal() == .OK { AppModel.shared.importFiles(panel.urls) }
    }
}

/// A photo or video handed over by the Photos picker, copied to a temporary file.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in PickedFile(url: try copy(received.file)) }
        FileRepresentation(importedContentType: .image) { received in PickedFile(url: try copy(received.file)) }
    }

    static func copy(_ file: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: out)
        return out
    }
}

/// The library window's drop target, in AppKit: files from Finder, file
/// promises from browsers and Photos (a dragged web image is a promise of
/// a JPEG, which SwiftUI's drop API gave nothing for), else raw image data.
final class LibraryDropView: NSView {
    /// The image's own bytes first (JPEG), converted renditions after.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [NSPasteboard.PasteboardType(UTType.jpeg.identifier), .png, .tiff]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
                                + Self.imageTypes)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.carriesMedia(sender.draggingPasteboard) else { return [] }
        MainActor.assumeIsolated { AppModel.shared.dropTargeted = true }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.carriesMedia(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { AppModel.shared.dropTargeted = false }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.dropTargeted = false }
        let pasteboard = sender.draggingPasteboard
        // 1. Files that exist (Finder).  A browser's drag also answers a
        //    "file URL": the promised file's, which does not exist yet.
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !files.isEmpty {
            MainActor.assumeIsolated { AppModel.shared.importFiles(files) }
            return true
        }
        // 2. The image itself on the pasteboard (a browser puts its bytes there).
        let name = Self.name(from: pasteboard)
        for type in Self.imageTypes {
            let utType = UTType(type.rawValue) ?? .png
            if let data = pasteboard.data(forType: type), let file = MediaDropFiles.write(data, as: utType, name: name) {
                MainActor.assumeIsolated { AppModel.shared.importFiles([file]) }
                return true
            }
        }
        // 3. File promises (Photos, a browser's video).
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("cp-drop-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let group = DispatchGroup()
            let found = FoundFiles()
            for promise in promises {
                group.enter()
                var left = promise.fileNames.count
                if left == 0 { group.leave(); continue }
                promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { url, error in
                    if error == nil { found.add(url) }
                    left -= 1
                    if left == 0 { group.leave() }
                }
            }
            group.notify(queue: .main) {
                MainActor.assumeIsolated { AppModel.shared.importFiles(found.all) }
            }
            return true
        }
        return false
    }

    /// A name for dropped image bytes: the dragged link's file name
    /// (Wikipedia's "File:Name.jpg" → "Name").
    static func name(from pasteboard: NSPasteboard) -> String {
        guard let link = pasteboard.string(forType: .URL).flatMap(URL.init(string:)) else { return "Dropped image" }
        var name = link.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? link.lastPathComponent
        if name.hasPrefix("File:") { name = String(name.dropFirst(5)) }
        name = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Dropped image" : String(name.prefix(80))
    }

    static func carriesMedia(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        return types.contains(.fileURL) || !types.isDisjoint(with: imageTypes)
            || !types.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }
}

enum MediaDropFiles {
    static func write(_ data: Data, as type: UTType, name: String = "Dropped image") -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-drop-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let file = dir.appendingPathComponent("\(safe).\(type.preferredFilenameExtension ?? "png")")
        return (try? data.write(to: file)) != nil ? file : nil
    }
}

/// Files gathered from a drop's providers, whose callbacks come on any queue.
final class FoundFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

