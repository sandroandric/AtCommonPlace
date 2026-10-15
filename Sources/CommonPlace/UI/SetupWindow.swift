import AppKit
import ApplicationServices
import CommonPlaceKit
import SwiftUI

/// Whether CommonPlace can keep and understand captures on this Mac.
struct SetupState: Equatable {
    static let completedKey = "setupCompleted"

    var screenRecording = false
    var accessibility = false
    /// nil: Ollama is not running (or not installed).
    var ollamaVersion: String?
    var missingModels: [String] = []

    var ollamaNewEnough: Bool {
        ollamaVersion.map { Models.isVersion($0, atLeast: Models.minimumOllama) } ?? false
    }

    var ready: Bool { screenRecording && accessibility && ollamaNewEnough && missingModels.isEmpty }

    /// One line for the menu and the sidebar.
    var headline: String {
        if !screenRecording { return "Allow Screen Recording" }
        if !accessibility { return "Allow Accessibility for the ⌘ ⌘ keys" }
        if ollamaVersion == nil { return "Ollama isn't running" }
        if !ollamaNewEnough { return "Update Ollama to \(Models.minimumOllama)+" }
        if !missingModels.isEmpty { return "Download the models" }
        return "Ready"
    }

    static func check(client: OllamaClient) async -> SetupState {
        var state = SetupState(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
        state.ollamaVersion = try? await client.version()
        if state.ollamaVersion != nil {
            let names = (try? await client.models()) ?? []
            state.missingModels = [AppModel.visionModel, Models.embedding].filter { !OllamaClient.has($0, in: names) }
        } else {
            state.missingModels = [AppModel.visionModel, Models.embedding]
        }
        return state
    }
}

@MainActor
enum SetupWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Set up CommonPlace"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            // A fixed size, drawn under the title bar too (the sky reaches the top).
            let hosting = NSHostingView(rootView: SetupView())
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setContentSize(NSSize(width: 560, height: 720))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

struct SetupView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var pulling: String?
    @State private var progress: Double = 0
    @State private var pullError: String?
    @State private var triedKeys = false
    @ObservedObject private var held = HotkeyMonitor.shared.held
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                TimelineView(.everyMinute) { context in
                    let calendar = Calendar.current
                    Horizon(phase: SkyPhase.at(hour: calendar.component(.hour, from: context.date),
                                               minute: calendar.component(.minute, from: context.date)))
                }
                VStack(alignment: .leading, spacing: 8) {
                    BrandMark(size: 40, onDark: true).padding(.bottom, 8)
                    Caption("Setup", color: Theme.ivory.opacity(0.62))
                    headline("Your", "commonplace book.", size: 44)
                        .kerning(-0.6)
                        .foregroundStyle(Theme.ivory)
                        .shadow(color: .black.opacity(0.3), radius: 12)
                }
                .padding(28)
            }
            .frame(height: 200)
            .overlay(alignment: .top) { WindowDragArea().frame(height: 44) }
            .environment(\.colorScheme, .dark)

            VStack(alignment: .leading, spacing: 0) {
                Text("Press both ⌘ keys on anything worth keeping. CommonPlace reads it, names it and files it, all on this Mac.")
                    .font(Theme.sans(13.5))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 20)

                step(1, done: model.setup.screenRecording, title: "Screen Recording",
                     detail: "To take a picture of the window you’re in, and nothing else.") {
                    Button("Allow") {
                        CGRequestScreenCaptureAccess()
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    }
                    .buttonStyle(InkButton())
                }
                step(2, done: model.setup.accessibility, title: "Accessibility",
                     detail: "To hear both ⌘ keys from any app, and read the page’s address.") {
                    Button("Allow") {
                        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                    }
                    .buttonStyle(InkButton())
                }
                step(3, done: model.setup.ollamaNewEnough, title: "Ollama", detail: ollamaDetail) {
                    if model.setup.ollamaVersion == nil, FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
                        Button("Open Ollama") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app")) }
                            .buttonStyle(InkButton())
                    } else {
                        Button(model.setup.ollamaVersion == nil ? "Download" : "Update") { open("https://ollama.com/download") }
                            .buttonStyle(InkButton())
                    }
                }
                step(4, done: model.setup.ollamaNewEnough && model.setup.missingModels.isEmpty, title: "Models",
                     detail: modelsDetail) {
                    if pulling != nil {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.wash).frame(width: 96, height: 4)
                            Capsule().fill(Theme.accent).frame(width: 96 * progress, height: 4)
                        }
                        .animation(Theme.fade, value: progress)
                    } else {
                        Button("Download") { pullModels() }
                            .buttonStyle(InkButton())
                            .disabled(!model.setup.ollamaNewEnough)
                    }
                }
                if let pullError {
                    Text(pullError).font(Theme.sans(12)).foregroundStyle(Theme.accent).padding(.top, 8)
                }
                step(5, done: triedKeys, title: "Try it", detail: "Press the keys on any window. Change them in Settings.") {
                    CaptureKeysView(pressed: held.left && held.right ? .both : held.left ? .left : held.right ? .right : .none)
                }

                Spacer(minLength: 16)
                Text("Your captures never leave your Mac. Once a day CommonPlace sends a check-in (a random ID, versions, and a count), which you can turn off in Settings.")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                HStack {
                    Caption(model.setup.ready ? "All set" : "Captures wait here until this is done")
                    Spacer()
                    Button("Open the library") {
                        UserDefaults.standard.set(true, forKey: SetupState.completedKey)
                        SetupWindow.close()
                        LibraryWindow.show()
                    }
                    .buttonStyle(InkButton())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientLight())
        .ignoresSafeArea()
        .animation(Theme.spring, value: model.setup)
        .task { await model.refreshSetup() }
        .onReceive(timer) { _ in Task { await model.refreshSetup() } }
        .onReceive(NotificationCenter.default.publisher(for: .commonPlaceKept)) { _ in withAnimation(Theme.spring) { triedKeys = true } }
    }

    private var ollamaDetail: String {
        guard let version = model.setup.ollamaVersion else { return "Runs the models on this Mac. It isn't running." }
        return model.setup.ollamaNewEnough
            ? "Ollama \(version) is running."
            : "Ollama \(version) is running; CommonPlace needs \(Models.minimumOllama) or later."
    }

    private var modelsDetail: String {
        let wanted = [AppModel.visionModel, Models.embedding]
        let list = wanted.map { "\($0) (\(Models.sizes[$0] ?? "?"))" }.joined(separator: " and ")
        if let pulling { return "Downloading \(pulling)… \(Int(progress * 100))%" }
        return model.setup.missingModels.isEmpty ? "\(list): ready." : "\(list): one reads and names, one files and finds."
    }

    private func step<Action: View>(_ number: Int, done: Bool, title: String, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().strokeBorder(done ? Theme.accent : Theme.hairline, lineWidth: 1)
                    .background(Circle().fill(done ? Theme.accent : .clear))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ground)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)").font(Theme.figures(10)).foregroundStyle(Theme.ink3)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.sans(13.5, .medium)).foregroundStyle(done ? Theme.ink3 : Theme.ink)
                Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !done { action() }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func pullModels() {
        pullError = nil
        let models = model.setup.missingModels
        Task {
            for name in models {
                pulling = name
                progress = 0
                do {
                    try await model.client.pull(model: name) { completed, total, _ in
                        guard total > 0 else { return }
                        Task { @MainActor in progress = Double(completed) / Double(total) }
                    }
                } catch {
                    pullError = "Couldn't download \(name): \(error)"
                    break
                }
            }
            pulling = nil
            await model.refreshSetup()
            Task { await model.library.work() }
        }
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

extension Notification.Name {
    /// A capture was kept (setup's "Try it" listens).
    static let commonPlaceKept = Notification.Name("CommonPlaceKept")
}
