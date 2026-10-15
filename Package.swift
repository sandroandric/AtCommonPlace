// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CommonPlace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CommonPlace", targets: ["CommonPlace"]),
        .executable(name: "commonplace-mcp", targets: ["commonplace-mcp"]),
        .library(name: "CommonPlaceKit", targets: ["CommonPlaceKit"]),
    ],
    targets: [
        // Everything that does not need a screen: the store, the hotkey and
        // window rules, Ollama, the understanding pipeline, organizing, search.
        .target(
            name: "CommonPlaceKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu-bar app: capture, the HUD, the library window, setup.
        .executableTarget(
            name: "CommonPlace",
            dependencies: ["CommonPlaceKit"]
        ),
        // The MCP server agents start (bundled in CommonPlace.app).
        .executableTarget(
            name: "commonplace-mcp",
            dependencies: ["CommonPlaceKit"]
        ),
        // Developer tool: runs the real pipeline over a folder of images and
        // reports what it made of them (thresholds are set from its output).
        .executableTarget(
            name: "cp-eval",
            dependencies: ["CommonPlaceKit"]
        ),
        .testTarget(
            name: "CommonPlaceKitTests",
            dependencies: ["CommonPlaceKit"]
        ),
    ]
)
