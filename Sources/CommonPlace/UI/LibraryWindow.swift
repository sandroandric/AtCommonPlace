import AppKit
import CommonPlaceKit
import SwiftUI

/// The library window.  CommonPlace lives in the menu bar; while this window
/// is open it is also a regular app (Dock, ⌘-Tab).
@MainActor
enum LibraryWindow {
    private static var window: NSWindow?
    private static var closeObserver: Any?
    private static var keyMonitor: Any?

    /// The library is the window the user is in (the capture keys then keep nothing).
    static var isFrontmost: Bool { NSApp.isActive && window?.isKeyWindow == true }

    static func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "CommonPlace"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(Theme.ground)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("CommonPlaceLibrary")
            window.minSize = NSSize(width: 980, height: 640)
            let hosting = NSHostingView(rootView: LibraryView())
            // The window keeps its own size; the view does not shrink it to its ideal.
            hosting.sizingOptions = []
            // The library sits in an AppKit container that takes drops (files,
            // browsers' file promises, image data); clicks reach the library.
            let container = LibraryDropView(frame: NSRect(x: 0, y: 0, width: 1320, height: 860))
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            window.contentView = container
            window.setContentSize(NSSize(width: 1320, height: 860))
            if !window.setFrameUsingName("CommonPlaceLibrary") { window.center() }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    AppModel.shared.selectedID = nil
                    _ = NSApp.setActivationPolicy(.accessory)
                }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let keyCode = event.keyCode, flags = event.modifierFlags, number = event.windowNumber
                let handled = MainActor.assumeIsolated { handle(keyCode: keyCode, flags: flags, windowNumber: number) }
                return handled ? nil : event
            }
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The open capture's keys: ← → to browse, esc to close, space to play
    /// or look closer, F to favourite.  Not while typing.
    private static func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
        guard let window, windowNumber == window.windowNumber, AppModel.shared.selectedID != nil,
              !(window.firstResponder is NSTextView),
              flags.intersection([.command, .control, .option]).isEmpty else { return false }
        let model = AppModel.shared
        switch keyCode {
        case 123: model.step(-1)
        case 124: model.step(1)
        case 53: withAnimation(Theme.spring) { model.selectedID = nil }
        case 49: NotificationCenter.default.post(name: .commonPlaceSpace, object: nil)
        case 3:
            if let capture = model.selected { model.toggleFavorite(capture) }
        default: return false
        }
        return true
    }
}

extension Notification.Name {
    /// Space in the open capture: play or pause a video, look closer at a picture.
    static let commonPlaceSpace = Notification.Name("CommonPlaceSpace")
}

struct LibraryView: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = model.selected
        ZStack {
            AmbientLight()
            // The top 60 pt move the window wherever nothing else is there.
            WindowDragArea()
                .frame(height: 60)
                .frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 0) {
                IndexSidebar()
                    .frame(width: 248)
                MainColumn()
            }
            .blur(radius: open == nil ? 0 : 24)
            .scaleEffect(open == nil || reduceMotion ? 1 : 0.985)
            .allowsHitTesting(open == nil)

            if let open {
                Theme.ground.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.spring) { model.selectedID = nil } }
                    .transition(.opacity)
                DetailSheet(capture: open)
                    .transition(reduceMotion ? .opacity
                                : .scale(scale: 0.96).combined(with: .opacity).combined(with: .offset(y: 16)))
                    .zIndex(1)
            }

            if model.dropTargeted { DropVeil().transition(.opacity) }
        }
        .animation(Theme.spring, value: open == nil)
        .animation(Theme.fade, value: model.dropTargeted)
        .tint(Theme.accent)
        .ignoresSafeArea()
    }
}

/// Files over the window: the ground lifts and says what will happen.
private struct DropVeil: View {
    var body: some View {
        ZStack {
            Theme.ground.opacity(0.82)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .padding(16)
            VStack(spacing: 16) {
                BrandMark(size: 88)
                headline("Let it go", "to keep it.", size: 36, closeColor: Theme.accent)
                    .foregroundStyle(Theme.ink)
                Caption("Photos and videos · read on this Mac")
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - The index

private struct IndexSidebar: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage("browseExpanded") private var browseExpanded = false
    @State private var renaming: CaptureCollection?
    @State private var markNodding = false
    @Namespace private var dot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: shutter) {
                HStack(spacing: 10) {
                    BrandMark(size: 22, nodding: markNodding)
                    Text("CommonPlace")
                        .font(Theme.serif(21, weight: 460))
                        .kerning(-0.3)
                        .foregroundStyle(Theme.ink)
                }
            }
            .buttonStyle(.plain)
            .help("CommonPlace")
            .padding(.top, 52)
            .padding(.leading, 24)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        row("Home", count: model.total, shelf: .recent)
                        row("Favorites", count: model.favoritesCount, shelf: .favorites)
                        row("Unsorted", count: model.unsortedCount, shelf: .unsorted)
                    }
                    .padding(.top, 28)

                    if !model.collections.isEmpty {
                        Caption("Collections")
                            .padding(.leading, 16)
                            .padding(.top, 28)
                            .padding(.bottom, 8)
                        ForEach(model.collections) { collection in
                            row(collection.name, count: collection.count, shelf: .collection(collection.id),
                                cover: model.covers[collection.id]?.first)
                                .contextMenu { Button("Rename…") { renaming = collection } }
                        }
                    }

                    if !model.kinds.isEmpty || !model.sources.isEmpty {
                        Button {
                            withAnimation(Theme.spring) { browseExpanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Caption("Browse")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(Theme.ink4)
                                    .rotationEffect(.degrees(browseExpanded ? 90 : 0))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 16)
                        .padding(.top, 28)
                        .padding(.bottom, 8)
                        if browseExpanded {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.kinds, id: \.0) { kind, count in
                                    row(kind.title, count: count, shelf: .kind(kind))
                                }
                                ForEach(model.sources.prefix(12), id: \.0) { source, count in
                                    row(source, count: count, shelf: .source(source))
                                }
                            }
                            .transition(.opacity.combined(with: .offset(y: -6)))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            SidebarFooter()
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .sheet(item: $renaming) { RenameCollectionSheet(collection: $0) }
    }

    /// The mark nods (a press and a tilt, then it settles), and the library goes home.
    private func shutter() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) { markNodding = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.45)) { markNodding = false }
        }
        withAnimation(Theme.spring) {
            model.query = ""
            model.shelf = .recent
        }
    }

    private func row(_ title: String, count: Int, shelf: Shelf, cover: Capture? = nil) -> some View {
        SidebarRow(title: title, count: count, cover: cover, active: model.shelf == shelf && !model.searchingNow, dot: dot) {
            withAnimation(Theme.spring) {
                model.query = ""
                model.shelf = shelf
            }
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let count: Int
    let cover: Capture?
    let active: Bool
    let dot: Namespace.ID
    let action: () -> Void
    @ObservedObject private var model = AppModel.shared
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let cover {
                    Thumbnail(capture: cover)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
                }
                Text(title)
                    .font(Theme.sans(13.5, active ? .medium : .regular))
                    .foregroundStyle(active || hovering ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(Theme.figures(11))
                    .foregroundStyle(active ? Theme.ink : Theme.ink4)
                    .contentTransition(.numericText())
            }
            .padding(.leading, 16)
            .frame(height: 32)
            .background(alignment: .leading) {
                if active {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .matchedGeometryEffect(id: "active", in: dot)
                } else if hovering {
                    Circle().fill(Theme.ink4.opacity(0.5)).frame(width: 4, height: 4).padding(.leading, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
        .animation(Theme.spring, value: count)
    }
}

/// A press sinks a little; nothing else changes.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

private struct SidebarFooter: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var held = HotkeyMonitor.shared.held

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if !model.setup.ready {
                Button { SetupWindow.show() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        Text(model.setup.headline).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.accent)
                    }
                }
                .buttonStyle(PressStyle())
            } else {
                HStack(spacing: 6) {
                    CaptureKeysView(pressed: held.left && held.right ? .both : held.left ? .left : held.right ? .right : .none)
                    Text("Keep what you see")
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.ink2)
                        .padding(.leading, 4)
                }
            }
            HStack(spacing: 8) {
                if model.importing > 0 || model.understanding > 0 {
                    Working()
                    Caption(model.importing > 0 ? "Adding \(model.importing)" : "Reading \(model.understanding)")
                } else {
                    Circle().fill(Theme.sage).frame(width: 6, height: 6)
                    Caption("All read, on this Mac")
                }
            }
            .animation(Theme.fade, value: model.understanding)
        }
    }
}

/// A small ring that turns while something is being read.
struct Working: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

struct RenameCollectionSheet: View {
    let collection: CaptureCollection
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Caption("Rename collection")
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.serif(28))
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                .onSubmit(save)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GhostButton())
                Button("Rename", action: save)
                    .buttonStyle(InkButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(Theme.surface)
        .onAppear { name = collection.name }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        AppModel.shared.renameCollection(collection.id, name: trimmed, emoji: collection.emoji)
        dismiss()
    }
}

// MARK: - The page

private struct MainColumn: View {
    @ObservedObject private var model = AppModel.shared

    private var page: String {
        if model.searchingNow { return "search" }
        switch model.shelf {
        case .recent: return "home"
        case .favorites: return "favorites"
        case .unsorted: return "unsorted"
        case .collection(let id): return "collection-\(id)"
        case .kind(let kind): return "kind-\(kind.rawValue)"
        case .source(let source): return "source-\(source)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
                .padding(.top, 20)
                .padding(.trailing, 40)
            ScrollView {
                Group {
                    if model.searchingNow {
                        SearchPage()
                    } else if model.shelf == .recent {
                        HomePage()
                    } else {
                        ShelfPage()
                    }
                }
                .id(page)
                .transition(.opacity.combined(with: .offset(y: 10)))
                .padding(.top, 20)
                .padding(.trailing, 40)
                .padding(.bottom, 56)
            }
            .scrollIndicators(.never)
            .animation(Theme.spring, value: page)
        }
    }
}

private struct TopBar: View {
    @ObservedObject private var model = AppModel.shared
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(focused ? Theme.ink : Theme.ink2)
                TextField("", text: $model.query, prompt: Text("Search what you’ve seen").foregroundColor(Theme.ink3))
                    .textFieldStyle(.plain)
                    .font(Theme.sans(13.5))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onExitCommand {
                        withAnimation(Theme.spring) { model.query = "" }
                        focused = false
                    }
                if model.searching {
                    Working()
                } else if !model.query.isEmpty {
                    Button {
                        withAnimation(Theme.spring) { model.query = "" }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.wash))
                    }
                    .buttonStyle(PressStyle())
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Text("⌘K")
                        .font(Theme.figures(10.5))
                        .foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.wash))
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(width: 440, height: 40)
            .background(Capsule().fill(Theme.raised.opacity(focused ? 1 : 0.72)))
            .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.45) : Theme.hairline))
            .background(Capsule().stroke(Theme.accentWash, lineWidth: focused ? 8 : 0).padding(-0.5))
            .shadow(color: Theme.shadow.opacity(focused ? 0.06 : 0.03), radius: focused ? 12 : 2, y: focused ? 8 : 1)
            .scaleEffect(hovering && !focused ? 1.005 : 1)
            .onHover { hovering = $0 }
            .animation(Theme.snappy, value: focused)
            .animation(Theme.fade, value: model.query.isEmpty)
            .background {
                Button("") { focused = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .hidden()
                Button("") { focused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            }

            Spacer()
            ImportButtons()
        }
        .frame(height: 40)
    }
}

/// The chosen capture keys, as caps; `pressed` sinks the held ones.
struct CaptureKeysView: View {
    enum Held { case none, left, right, both }
    var pressed: Held = .none
    @AppStorage(HotkeyMonitor.keysDefault) private var raw = CaptureKeys.bothCommands.rawValue

    var body: some View {
        let caps = (CaptureKeys(rawValue: raw) ?? .bothCommands).caps
        HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { index, cap in
                KeyCap(cap, pressed: caps.count == 2 && (pressed == .both || (index == 0 && pressed == .left)
                                                          || (index == 1 && pressed == .right)))
            }
        }
    }
}

// MARK: - Buttons

/// The one filled button: ink, ivory words.
struct InkButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(13, .medium))
            .foregroundStyle(Theme.ground)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(Theme.ink))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .shadow(color: Theme.shadow.opacity(0.18), radius: 1, y: 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Words that act, with a wash on hover.
struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostLabel(configuration: configuration)
    }

    private struct GhostLabel: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.sans(13))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(hovering ? Theme.wash : .clear))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.fade, value: hovering)
                .animation(Theme.snappy, value: configuration.isPressed)
        }
    }
}
