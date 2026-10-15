import CommonPlaceKit
import Foundation

// commonplace-mcp: CommonPlace's MCP server over stdio. One JSON-RPC
// message per line in, one reply per line out; logs go to stderr.
let store: LibraryStore
do {
    store = try LibraryStore(root: LibraryStore.defaultRoot)
} catch {
    FileHandle.standardError.write(Data("commonplace-mcp: cannot open the library at \(LibraryStore.defaultRoot.path): \(error)\n".utf8))
    exit(1)
}
// Inside CommonPlace.app this binary has the app's identity, so its settings
// are the standard ones; run from elsewhere (swift run), read the app's.
let appID = "com.sandroandric.commonplace"
let settings = Bundle.main.bundleIdentifier == appID ? UserDefaults.standard : UserDefaults(suiteName: appID)
let visionModel = settings?.string(forKey: "visionModel") ?? Models.vision()
let server = MCPServer(library: Library(store: store, visionModel: visionModel), store: store,
                       version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let reply = await server.handle(line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
}
