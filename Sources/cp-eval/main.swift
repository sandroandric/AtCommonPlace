import CommonPlaceKit
import Foundation

// cp-eval <images dir> [manifest.tsv] [--ollama URL] [--model name] [--query "text" ...]
//
// Keeps every PNG of the folder in a throwaway library (window title from
// the manifest: "<file stem>\t<app> — <title>"), runs the real pipeline
// (OCR, the vision model, EmbeddingGemma 2, the organizer), then prints what
// each became, the collections, the similarity spread and each query's results.

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
var queries: [String] = []
while let q = option("--query") { queries.append(q) }
let host = URL(string: option("--ollama") ?? "http://127.0.0.1:11434")!
let visionModel = option("--model") ?? Models.vision()
guard let dir = args.first.map({ URL(fileURLWithPath: $0) }) else {
    print("usage: cp-eval <images dir> [manifest.tsv] [--ollama URL] [--model name] [--query text]...")
    exit(2)
}
var titles: [String: (String, String)] = [:]
if args.count > 1, let manifest = try? String(contentsOfFile: args[1], encoding: .utf8) {
    for line in manifest.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let appTitle = parts[1].components(separatedBy: " — ")
        titles[parts[0]] = (appTitle.first ?? "", appTitle.dropFirst().joined(separator: " — "))
    }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-eval-\(UUID().uuidString)")
let store = try LibraryStore(root: root)
let library = Library(store: store, client: OllamaClient(host: host), visionModel: visionModel)
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.path < $1.path }
var stems: [String: String] = [:]
for (i, file) in files.enumerated() {
    let png = try Data(contentsOf: file)
    let stem = file.deletingPathExtension().lastPathComponent
    let (app, title) = titles[stem] ?? ("Safari", stem)
    let capture = Capture(createdAt: Date().addingTimeInterval(Double(i)), app: app, windowTitle: title, width: 0, height: 0)
    stems[capture.id] = stem
    try await library.keep(capture, png: png, thumbnail: Thumbnailer.jpeg(from: png, maxPixel: 480, quality: 0.8) ?? png)
}
let started = Date()
await library.work()
print("Understood \(files.count) captures with \(visionModel) in \(Int(Date().timeIntervalSince(started))) s\n")

let all = try store.captures(.recent, limit: 10_000).reversed()
for c in all {
    print("[\(stems[c.id] ?? c.id)] \(c.displayTitle)  ·  \(c.kind?.rawValue ?? "-")  ·  \(c.tags.joined(separator: ", "))")
    print("    \(c.summary ?? "")")
    if !c.highlights.isEmpty { print("    “\(c.highlights[0])”") }
    if let error = c.lastError { print("    ERROR: \(error)") }
}

print("\nCollections:")
for collection in try store.collections() {
    let members = try store.captures(.collection(collection.id)).map { stems[$0.id] ?? "?" }
    print("  \(collection.emoji) \(collection.name): \(members.sorted().joined(separator: ", "))")
}
print("  Unsorted: \(try store.captures(.unsorted).map { stems[$0.id] ?? "?" }.sorted().joined(separator: ", "))")

for space in VectorSpace.allCases {
    let vectors = try store.vectors(model: Models.embedding, space: space)
    var pairs: [(Float, String, String)] = []
    for i in vectors.indices { for j in vectors.indices where j > i {
        pairs.append((VectorMath.dot(vectors[i].vector, vectors[j].vector), stems[vectors[i].id] ?? "?", stems[vectors[j].id] ?? "?"))
    } }
    pairs.sort { $0.0 > $1.0 }
    print("\nMost similar pairs (\(space.rawValue)):")
    for p in pairs.prefix(10) { print(String(format: "  %.3f  %@ ~ %@", p.0, p.1, p.2)) }
    let scores = pairs.map(\.0).sorted()
    if !scores.isEmpty {
        print(String(format: "Pair similarity (%@): min %.3f, median %.3f, p90 %.3f, max %.3f", space.rawValue,
                     scores.first!, scores[scores.count / 2], scores[Int(Double(scores.count) * 0.9)], scores.last!))
    }
}

for query in queries {
    let found = await library.search(query)
    print("\nSearch “\(query)”: \(found.prefix(5).map { stems[$0.id] ?? "?" }.joined(separator: ", "))")
}
print("\nLibrary kept at \(root.path)")
