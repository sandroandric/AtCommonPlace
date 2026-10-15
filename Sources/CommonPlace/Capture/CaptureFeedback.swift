import AppKit
import CommonPlaceKit
import SwiftUI

/// What the user sees when something is kept: a viewfinder's corners close
/// on it, and an island drops from under the menu bar with its picture, its
/// name once read, and where it was filed.  The island waits while the
/// pointer is on it or a note is being written, and leaves on its own.
@MainActor
final class CaptureFeedback {
    static let shared = CaptureFeedback()

    private var panel: FeedbackPanel?
    private var shutter: NSWindow?
    private var dismissal: Task<Void, Never>?
    let state = IslandState()

    /// The island's window: wide and tall enough for its largest state; the
    /// island draws itself at the top centre, the rest is clear (clicks pass).
    private static let panelSize = NSSize(width: 520, height: 200)

    func show(_ shot: WindowCapturer.Shot) {
        showKept(shot.capture, image: NSImage(cgImage: shot.image, size: .zero), over: shot.frame, heading: "Kept · the window")
    }

    /// Something was kept: the corners close over where it was, then the island.
    func showKept(_ capture: Capture, image: NSImage, over frame: CGRect?, heading: String) {
        if let frame { closeShutter(over: frame) }
        let sound = NSSound(named: "Tink")
        sound?.volume = 0.5
        sound?.play()
        present { $0.kept(capture: capture, image: image, heading: heading) }
    }

    /// A video is being recorded: the island stays, with the time and the
    /// sound's level, until it stops.
    func showRecording(over frame: CGRect, level: @escaping @Sendable () -> Float) {
        closeShutter(over: frame)
        let sound = NSSound(named: "Pop")
        sound?.volume = 0.5
        sound?.play()
        present { $0.recording(level: level) }
        dismissal?.cancel()
    }

    func showProblem(_ message: String, action: String?, perform: (() -> Void)?) {
        present { $0.problem(message, action: action, perform: perform) }
    }

    /// The keys pressed in CommonPlace's own window.
    func showSelf() {
        present { $0.itself() }
    }

    /// Keep the island while the user is on it; let it go after `seconds` otherwise.
    func scheduleDismiss(after seconds: Double = 4.5) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if case .recording = self.state.mode { return }
            if self.state.hovering || self.state.editingNote {
                self.scheduleDismiss(after: 1.5)
            } else {
                self.dismiss()
            }
        }
    }

    func dismiss() {
        dismissal?.cancel()
        guard let panel, state.visible else { return }
        withAnimation(Theme.spring) { state.visible = false }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !self.state.visible else { return }
            panel.orderOut(nil)
            self.state.editingNote = false
        }
    }

    /// The island takes the keyboard (for the note) without activating the
    /// app behind it.
    func focusNote() {
        panel?.makeKey()
        withAnimation(Theme.spring) { state.editingNote = true }
    }

    private func present(_ change: (IslandState) -> Void) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            let size = Self.panelSize
            // Just under the menu bar (and the notch), centred.
            let top = screen.visibleFrame.maxY
            panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                           display: false)
        }
        let wasVisible = state.visible
        if !wasVisible { state.visible = false }
        change(state)
        panel.orderFrontRegardless()
        if wasVisible {
            withAnimation(Theme.spring) { state.revision += 1 }
        } else {
            DispatchQueue.main.async { withAnimation(Theme.spring) { self.state.visible = true } }
        }
        scheduleDismiss()
    }

    private func makePanel() -> FeedbackPanel {
        let panel = FeedbackPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                                  styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        let host = NSHostingView(rootView: Island(state: state))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// A viewfinder's four corners close on what was kept, and a faint veil
    /// lifts off it, like a shutter.
    private func closeShutter(over frame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        // CGWindow frames are top-left based; AppKit's are bottom-left.
        let rect = NSRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            .insetBy(dx: -24, dy: -24)
        let window = shutter ?? {
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return window
        }()
        shutter = window
        window.setFrame(rect, display: false)
        let host = NSHostingView(rootView: Shutter())
        host.sizingOptions = []
        window.contentView = host
        window.alphaValue = 1
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                window.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { window.orderOut(nil) }
            })
        }
    }
}

final class FeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The corners, from 24 pt out to the kept frame's edge, over a veil that fades.
private struct Shutter: View {
    @State private var closed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.ivory.opacity(closed ? 0 : 0.28)).padding(24)
            Corners(inset: closed ? 24 : 0)
                .stroke(Theme.ivory, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.35), radius: 3)
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.01) : .spring(response: 0.32, dampingFraction: 0.72)) { closed = true }
        }
    }

    /// Four corners `inset` in from the edges, their arms a fifth of the
    /// shorter side (48 pt at most).
    private struct Corners: Shape {
        var inset: CGFloat
        var animatableData: CGFloat {
            get { inset }
            set { inset = newValue }
        }

        func path(in bounds: CGRect) -> Path {
            let r = bounds.insetBy(dx: inset, dy: inset)
            let arm = min(48, r.width / 5, r.height / 5)
            var path = Path()
            path.move(to: CGPoint(x: r.minX, y: r.minY + arm)); path.addLine(to: CGPoint(x: r.minX, y: r.minY)); path.addLine(to: CGPoint(x: r.minX + arm, y: r.minY))
            path.move(to: CGPoint(x: r.maxX - arm, y: r.minY)); path.addLine(to: CGPoint(x: r.maxX, y: r.minY)); path.addLine(to: CGPoint(x: r.maxX, y: r.minY + arm))
            path.move(to: CGPoint(x: r.maxX, y: r.maxY - arm)); path.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); path.addLine(to: CGPoint(x: r.maxX - arm, y: r.maxY))
            path.move(to: CGPoint(x: r.minX + arm, y: r.maxY)); path.addLine(to: CGPoint(x: r.minX, y: r.maxY)); path.addLine(to: CGPoint(x: r.minX, y: r.maxY - arm))
            return path
        }
    }
}

@MainActor
final class IslandState: ObservableObject {
    enum Mode {
        case kept
        case recording
        case problem
        /// The keys pressed in CommonPlace itself.
        case itself
    }

    @Published var mode: Mode = .kept
    @Published var visible = false
    /// Bumped when the island changes while it shows (for a small bounce).
    @Published var revision = 0
    @Published var captureID: String?
    @Published var image: NSImage?
    @Published var heading = ""
    @Published var detail = ""
    @Published var problem = ""
    @Published var problemAction: String?
    var problemPerform: (() -> Void)?
    @Published var note = ""
    @Published var hovering = false
    @Published var editingNote = false
    @Published var noteSaved = false
    @Published var recordingSince: Date?
    var level: (@Sendable () -> Float)?

    func kept(capture: Capture, image: NSImage, heading: String) {
        mode = .kept
        recordingSince = nil
        level = nil
        captureID = capture.id
        self.image = image
        self.heading = heading
        detail = capture.windowTitle.isEmpty ? capture.app : capture.windowTitle
        note = ""
        noteSaved = false
        editingNote = false
    }

    func recording(level: @escaping @Sendable () -> Float) {
        mode = .recording
        recordingSince = Date()
        self.level = level
        captureID = nil
        image = nil
        editingNote = false
    }

    func problem(_ message: String, action: String?, perform: (() -> Void)?) {
        mode = .problem
        recordingSince = nil
        level = nil
        captureID = nil
        image = nil
        problem = message
        problemAction = action
        problemPerform = perform
        editingNote = false
    }

    func itself() {
        mode = .itself
        recordingSince = nil
        level = nil
        captureID = nil
        image = nil
        editingNote = false
    }
}

/// The island: a capsule that drops from under the menu bar, grows to its
/// content, and goes back up.
struct Island: View {
    @ObservedObject var state: IslandState
    @ObservedObject private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            content
                .padding(.vertical, 8)
                .padding(.leading, state.mode == .kept ? 8 : 16)
                .padding(.trailing, 16)
                .frame(width: state.editingNote ? 400 : nil)
                .frame(minWidth: 220, maxWidth: 440, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: state.editingNote ? 22 : 28, style: .continuous)
                        .fill(Theme.surface.opacity(0.96))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: state.editingNote ? 22 : 28, style: .continuous))
                )
                .overlay(RoundedRectangle(cornerRadius: state.editingNote ? 22 : 28, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: Theme.shadow.opacity(0.05), radius: 2, y: 2)
                .shadow(color: Theme.shadow.opacity(0.14), radius: 20, y: 16)
                .scaleEffect(state.visible || reduceMotion ? 1 : 0.6, anchor: .top)
                .offset(y: state.visible || reduceMotion ? 8 : -36)
                .opacity(state.visible ? 1 : 0)
                .onHover { state.hovering = $0 }
                .animation(Theme.spring, value: state.editingNote)
                .animation(Theme.spring, value: understood?.collectionID)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch state.mode {
        case .kept: kept
        case .recording: recording
        case .problem: problem
        case .itself: itself
        }
    }

    /// The capture once read (its title and collection), when it is the one shown.
    private var understood: Capture? {
        guard let kept = model.lastKept, kept.id == state.captureID else { return nil }
        return kept
    }

    private var kept: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if let image = state.image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Theme.well
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.hairline))

                VStack(alignment: .leading, spacing: 2) {
                    if let milestone = Wording.milestone(total: model.total), understood != nil, model.newest?.id == state.captureID {
                        HStack(spacing: 6) {
                            Confetti()
                            Caption(milestone, color: Theme.accent)
                        }
                    } else {
                        Caption(state.heading, color: Theme.accent)
                    }
                    Text(understood?.title ?? state.detail)
                        .font(Theme.sans(13.5, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: 260, alignment: .leading)

                Spacer(minLength: 0)
                if let collection = model.collection(understood?.collectionID) {
                    Text("→ \(collection.name)")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.wash))
                        .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                } else if !state.editingNote {
                    Button { CaptureFeedback.shared.focusNote() } label: {
                        Text(state.noteSaved ? "Noted" : "Note")
                            .font(Theme.sans(12, .medium))
                            .foregroundStyle(state.noteSaved ? Theme.accent : Theme.ink2)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Theme.wash))
                    }
                    .buttonStyle(PressStyle())
                    .opacity(state.hovering || state.noteSaved ? 1 : 0)
                }
            }
            if state.editingNote { NoteLine(state: state).transition(.opacity.combined(with: .offset(y: -6))) }
        }
        .frame(minHeight: 40)
    }

    private var recording: some View {
        HStack(spacing: 12) {
            Pulse()
            VStack(alignment: .leading, spacing: 4) {
                Caption("Recording", color: Theme.accent)
                if let level = state.level { LevelBars(level: level) }
            }
            Spacer(minLength: 16)
            if let since = state.recordingSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(since)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                            .font(Theme.figures(12))
                            .foregroundStyle(Theme.ink)
                        HStack(spacing: 3) {
                            CaptureKeysView()
                                .scaleEffect(0.8)
                            Text("to stop").font(Theme.sans(11)).foregroundStyle(Theme.ink3)
                        }
                    }
                }
            }
        }
        .frame(width: 300, height: 40)
        .overlay(alignment: .bottom) {
            if let since = state.recordingSince {
                TimelineView(.animation(minimumInterval: 0.5)) { context in
                    GeometryReader { geometry in
                        let share = min(1, context.date.timeIntervalSince(since) / VideoRecorder.maximumSeconds)
                        Capsule().fill(Theme.accent.opacity(0.5))
                            .frame(width: geometry.size.width * share, height: 1.5)
                    }
                }
                .frame(height: 1.5)
                .offset(y: 7)
            }
        }
    }

    private var problem: some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.ink4).frame(width: 6, height: 6)
            Text(state.problem)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
            if let action = state.problemAction {
                Button(action) {
                    state.problemPerform?()
                    CaptureFeedback.shared.dismiss()
                }
                .buttonStyle(.plain)
                .font(Theme.sans(12.5, .medium))
                .foregroundStyle(Theme.accent)
            }
        }
        .frame(minHeight: 40)
    }

    private var itself: some View {
        HStack(spacing: 12) {
            ShutterMark()
            VStack(alignment: .leading, spacing: 2) {
                Caption("Nothing to keep", color: Theme.accent)
                Text("That’s me. I keep the others.")
                    .font(Theme.serif(17, italic: true))
                    .foregroundStyle(Theme.ink)
            }
        }
        .frame(minHeight: 40)
    }
}

/// The note, written in the island: return keeps it, esc lets it go.
private struct NoteLine: View {
    @ObservedObject var state: IslandState
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $state.note, prompt: Text("Why you kept it").foregroundColor(Theme.ink4))
            .textFieldStyle(.plain)
            .font(Theme.serif(17))
            .foregroundStyle(Theme.ink)
            .focused($focused)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.accent).frame(height: 1) }
            .padding(.leading, 8)
            .onAppear { focused = true }
            .onSubmit(save)
            .onExitCommand {
                state.editingNote = false
                CaptureFeedback.shared.dismiss()
            }
    }

    private func save() {
        if let id = state.captureID, !state.note.trimmingCharacters(in: .whitespaces).isEmpty {
            AppModel.shared.setNote(id, state.note)
            state.noteSaved = true
        }
        withAnimation(Theme.spring) { state.editingNote = false }
        CaptureFeedback.shared.scheduleDismiss(after: 1.2)
    }
}

/// The recording dot, breathing.
private struct Pulse: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 12, height: 12)
            .background(Circle().fill(Theme.accent.opacity(0.18)).scaleEffect(on ? 2.1 : 1.2))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// The sound's level as it is recorded: the newest bar at right.
private struct LevelBars: View {
    let level: @Sendable () -> Float
    @State private var history: [CGFloat] = Array(repeating: 0, count: 20)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { context in
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, value in
                    Capsule().fill(Theme.ink.opacity(value > 0.02 ? 1 : 0.18))
                        .frame(width: 2, height: 2 + value * 12)
                }
            }
            .frame(height: 14)
            .onChange(of: context.date) { _, _ in
                history.removeFirst()
                history.append(CGFloat(level()))
            }
        }
    }
}

/// A burst of printed dots, once (a milestone).
private struct Confetti: View {
    @State private var out = false

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill([Theme.clay, Theme.sage, Theme.sky, Theme.yellow, Theme.accent, Theme.oat][index])
                    .frame(width: 4, height: 4)
                    .offset(x: out ? cos(Double(index) * .pi / 3) * 9 : 0, y: out ? sin(Double(index) * .pi / 3) * 9 : 0)
                    .opacity(out ? 0 : 1)
            }
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
        }
        .frame(width: 10, height: 10)
        .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.1)) { out = true } }
    }
}

/// The mark, nodding once.
private struct ShutterMark: View {
    @State private var nodding = false

    var body: some View {
        BrandMark(size: 30, nodding: nodding)
            .onAppear {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.7).delay(0.15)) { nodding = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.45)) { nodding = false }
                }
            }
    }
}
