import AppKit
import ApplicationServices
import CommonPlaceKit
import SwiftUI

@main
struct CommonPlaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(nsImage: HorizonMark.menuBarImage())
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.show() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("Keep This Window") { AppModel.shared.captureNow() }
                Button("Import Photos and Videos…") { ImportPanel.run() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var accessibilityPoll: Timer?
    private var workTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Theme.registerFonts()
        let model = AppModel.shared
        HotkeyMonitor.shared.onGesture = { model.captureNow() }
        HotkeyMonitor.shared.start()
        watchAccessibility()
        // Browsers' page trees, for the image or video under the pointer.
        PagePointer.startPreparing()

        // Captures waiting for Ollama are tried again every minute.
        workTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { await AppModel.shared.library.work() }
        }
        CheckInService.shared.start()

        Task {
            await model.refreshSetup()
            if !model.setup.ready || !UserDefaults.standard.bool(forKey: SetupState.completedKey) {
                SetupWindow.show()
            }
        }
    }

    /// The global key monitor hears nothing until Accessibility is granted:
    /// restart it the moment it is.
    private func watchAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.accessibilityPoll = nil
                HotkeyMonitor.shared.start()
                Task { await AppModel.shared.refreshSetup() }
            }
        }
    }

    /// Open With CommonPlace, or files dropped on its Dock icon: added to the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.importFiles(urls)
        LibraryWindow.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LibraryWindow.show()
        return true
    }
}

/// The menu bar window: the keys, what was just kept, the library, setup.
struct MenuContent: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("CommonPlace").font(Theme.serif(20)).foregroundStyle(Theme.ink)
                Spacer()
                Caption("\(model.total) kept")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 12)

            if !model.setup.ready {
                MenuRow(title: model.setup.headline, accent: true) { SetupWindow.show() }
            }
            MenuRow(title: "Keep this window", keys: AnyView(CaptureKeysView())) {
                // Let the menu close so the window under it is the frontmost again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.captureNow() }
            }
            MenuRow(title: "Import photos & videos", shortcut: "⇧⌘I") { ImportPanel.run() }

            let recent = model.latest
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Caption("Just kept")
                        Spacer()
                        if model.understanding > 0 {
                            Working()
                            Caption("Reading \(model.understanding)")
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(recent) { capture in
                            Button { open(capture) } label: {
                                Thumbnail(capture: capture)
                                    .frame(width: 56, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
                            }
                            .buttonStyle(PressStyle())
                            .help(capture.displayTitle)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 8) }
                .padding(.top, 8)
            }

            VStack(spacing: 0) {
                MenuRow(title: "Open the library", shortcut: "⌘L") { LibraryWindow.show() }
                    .keyboardShortcut("l")
                MenuRow(title: "Settings", shortcut: "⌘,", muted: true) { SettingsWindow.show() }
                    .keyboardShortcut(",")
                MenuRow(title: "Quit CommonPlace", shortcut: "⌘Q", muted: true) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 8) }
        }
        .padding(8)
        .frame(width: 280)
        .background(Theme.surface)
    }

    private func open(_ capture: Capture) {
        model.query = ""
        model.shelf = .recent
        model.selectedID = capture.id
        LibraryWindow.show()
    }
}

/// A row of the menu bar window: words, and its keys at right; a wash on hover.
private struct MenuRow: View {
    let title: String
    var shortcut: String?
    var keys: AnyView?
    var accent = false
    var muted = false
    let action: () -> Void
    @State private var hovering = false

    init(title: String, shortcut: String? = nil, keys: AnyView? = nil, accent: Bool = false, muted: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.keys = keys
        self.accent = accent
        self.muted = muted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if accent { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                Text(title)
                    .font(Theme.sans(13, accent ? .medium : .regular))
                    .foregroundStyle(accent ? Theme.accent : muted ? Theme.ink2 : Theme.ink)
                Spacer()
                if let keys { keys.scaleEffect(0.85) }
                if let shortcut { Text(shortcut).font(Theme.figures(11)).foregroundStyle(Theme.ink3) }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.wash : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}
