import AppKit
import CommonPlaceKit
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "CommonPlace Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView())
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Capture keys, the vision model, the library on disk, launch at login and
/// how agents connect.
struct SettingsView: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(HotkeyMonitor.keysDefault) private var keysRaw = CaptureKeys.bothCommands.rawValue
    @State private var installedModels: [String] = []
    @State private var visionModel = AppModel.visionModel
    @State private var librarySize: Int64?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage(CheckInService.enabledKey) private var checkInEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Settings")
                    Text("How CommonPlace keeps").font(Theme.serif(36)).kerning(-0.5).foregroundStyle(Theme.ink)
                }
                .padding(.top, 44)

                group("Keep") {
                    row("Capture keys") {
                        Picker("", selection: Binding(
                            get: { CaptureKeys(rawValue: keysRaw) ?? .bothCommands },
                            set: { HotkeyMonitor.keys = $0; keysRaw = $0.rawValue }
                        )) {
                            ForEach(CaptureKeys.allCases, id: \.self) { keys in Text(keys.title).tag(keys) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    note((CaptureKeys(rawValue: keysRaw) ?? .bothCommands) == .shortcut
                         ? "Control, Option, Command and K together, in any app."
                         : "Left and right together. A shortcut typed with one of them never keeps anything.")
                }

                group("Understanding") {
                    row("Vision model") {
                        Picker("", selection: Binding(get: { visionModel }, set: { pick($0) })) {
                            ForEach(visionChoices, id: \.self) { name in
                                Text(name + (name == Models.vision() ? "  (recommended)" : "")).tag(name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    row("Search and collections") {
                        Text(Models.embedding).font(Theme.figures(12)).foregroundStyle(Theme.ink2)
                    }
                    note("Both run in Ollama on this Mac. The vision model reads each capture once; a larger one writes better titles and summaries, more slowly.")
                }

                group("Library") {
                    row("Kept") { Text("\(model.total)").font(Theme.figures(12)).foregroundStyle(Theme.ink2) }
                    row("On disk") {
                        Text(librarySize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .font(Theme.figures(12)).foregroundStyle(Theme.ink2)
                    }
                    row(LibraryStore.defaultRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.defaultRoot]) }
                            .buttonStyle(GhostButton())
                    }
                }

                group("General") {
                    row("Open CommonPlace at login") {
                        Toggle("", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.accent)
                    }
                    if let loginError { note(loginError, color: Theme.accent) }
                    row("Send a daily check-in") {
                        Toggle("", isOn: $checkInEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.accent)
                    }
                    note("Once a day: a random ID, the app and macOS versions, and how many things you kept, as a number. Never what you kept. It tells us how many Macs use CommonPlace.")
                }

                AgentsSection()
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) { WindowDragArea().frame(height: 36) }
        .frame(width: 600, height: 680)
        .background(AmbientLight())
        .tint(Theme.accent)
        .task {
            installedModels = (try? await model.client.models()) ?? []
            librarySize = await Task.detached { Self.size(of: LibraryStore.defaultRoot) }.value
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption(title).padding(.bottom, 8)
            content()
        }
        .padding(.top, 32)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title).font(Theme.sans(13.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 16)
            control()
        }
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func note(_ text: String, color: Color = Theme.ink3) -> some View {
        Text(text).font(Theme.sans(12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
    }

    /// Installed models that can look at images, plus the recommended ones.
    private var visionChoices: [String] {
        let known = ["qwen3.5:4b", "qwen3.5:2b-q4_K_M", "gemma4:12b-it-qat", "qwen3.5:9b"]
        let installed = installedModels.filter { name in
            !name.contains("embed") && (name.hasPrefix("qwen3.5") || name.hasPrefix("gemma") || name.contains("vl") || name.contains("llava"))
        }
        return Array(Set(installed + known.filter { OllamaClient.has($0, in: installedModels) } + [Models.vision(), visionModel])).sorted()
    }

    private func pick(_ name: String) {
        visionModel = name
        model.setVisionModel(name)
        Task { await model.refreshSetup() }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS refused: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// How agents reach CommonPlace: its MCP server, bundled in the app.
/// Nothing runs until the user adds it to an agent.
struct AgentsSection: View {
    @State private var copied: String?

    private var server: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/commonplace-mcp").path
    }

    private var claudeCode: String { "claude mcp add commonplace -- \"\(server)\"" }

    private var json: String {
        """
        "commonplace": { "command": "\(server)" }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption("Agents")
            Text("Let Claude Code, Codex or any MCP client search what you kept: titles, summaries, passages, notes and what was said. Never images. Nothing runs until you add it to an agent.")
                .font(Theme.sans(12.5))
                .lineSpacing(4)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            command("Claude Code", claudeCode)
            command("Other MCP clients (mcpServers)", json)
        }
        .padding(.top, 32)
    }

    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Button(copied == text ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    withAnimation(Theme.fade) { copied = text }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Theme.fade) { if copied == text { copied = nil } } }
                }
                .buttonStyle(.plain)
                .font(Theme.sans(12, .medium))
                .foregroundStyle(copied == text ? Theme.accent : Theme.ink2)
            }
            Text(text)
                .font(Theme.figures(11))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}
