import AVFoundation
import AppKit
import CommonPlaceKit
import QuickLookUI
import SwiftUI

/// One capture, opened: a centred sheet over the softened library.  The
/// picture (or the video, playing) on a dark stage at left; what it is,
/// what was said, where it lives and your note at right.
struct DetailSheet: View {
    let capture: Capture

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width - 96, 1184)
            let height = min(geometry.size.height - 80, 776)
            HStack(spacing: 0) {
                MediaStage(capture: capture)
                    .frame(width: (width * 0.574).rounded())
                WordsPane(capture: capture)
            }
            .frame(width: width, height: height)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: Theme.shadow.opacity(0.04), radius: 2, y: 2)
            .shadow(color: Theme.shadow.opacity(0.14), radius: 40, y: 32)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

// MARK: - The stage

private struct MediaStage: View {
    let capture: Capture
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x101828), Color(hex: 0x15131A), Color(hex: 0x120D0C)],
                           startPoint: .top, endPoint: .bottom)
            Grain(tone: .light, opacity: 0.42)
            VStack(spacing: 0) {
                HStack {
                    Caption(facts, color: Theme.ivory.opacity(0.5))
                    Spacer()
                    if capture.media == .video {
                        Caption(capture.transcript?.isEmpty == false ? "Sound on" : "No words heard", color: Theme.ivory.opacity(0.5))
                    }
                }
                .frame(height: 64)
                .padding(.horizontal, 24)
                if capture.media == .video, let url = model.originalURL(capture) {
                    VideoStage(capture: capture, url: url)
                } else {
                    StillStage(capture: capture)
                }
            }
        }
        .id(capture.id)
        .transition(.opacity)
    }

    /// "Video · 0:10 · 1920 × 1080", "Photo · taken 12 May 2024", "Screen · Comet".
    private var facts: String {
        var parts: [String] = []
        switch capture.media {
        case .video:
            parts.append("Video")
            if let duration = capture.duration {
                parts.append(Duration.seconds(duration).formatted(.time(pattern: duration >= 3_600 ? .hourMinuteSecond : .minuteSecond)))
            }
        case .photo:
            parts.append("Photo")
            if let taken = capture.takenAt { parts.append("Taken " + taken.formatted(.dateTime.day().month(.abbreviated).year())) }
        case .screen:
            parts.append("Screen")
            if !capture.app.isEmpty { parts.append(capture.app) }
        }
        parts.append("\(capture.width) × \(capture.height)")
        return parts.joined(separator: " · ")
    }
}

/// A picture on the stage: whole, shadowed; double-click or space to look closer.
private struct StillStage: View {
    let capture: Capture
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Group {
            if let image = model.image(for: capture, full: true) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 16)
            } else {
                BrandMark(size: 44, onDark: true)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture(count: 2) { QuickLook.show(model.imageURL(capture)) }
        .help("Double-click or press space to look closer")
        .onReceive(NotificationCenter.default.publisher(for: .commonPlaceSpace)) { _ in
            QuickLook.show(model.imageURL(capture))
        }
    }
}

/// The video's player, with the time and position observed.
@MainActor
final class PlayerState: ObservableObject {
    let player: AVPlayer
    @Published var time: Double = 0
    @Published var duration: Double
    @Published var playing = false
    private var observer: Any?
    private var endObserver: Any?

    init(url: URL, duration: Double) {
        player = AVPlayer(url: url)
        self.duration = max(duration, 0.1)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds.isFinite ? time.seconds : 0
                self.playing = self.player.rate != 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.playing = false
            }
        }
    }

    func toggle() {
        if player.rate == 0 { player.play() } else { player.pause() }
        playing = player.rate != 0
    }

    func seek(_ seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        time = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
    }
}

/// The video: the picture, a play button that steps aside while it plays,
/// the six key frames (a click goes there) and a scrubber.
private struct VideoStage: View {
    let capture: Capture
    @StateObject private var state: PlayerState
    @ObservedObject private var model = AppModel.shared
    @State private var hovering = false
    @State private var frames: [NSImage] = []

    init(capture: Capture, url: URL) {
        self.capture = capture
        _state = StateObject(wrappedValue: PlayerState(url: url, duration: capture.duration ?? 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                PlayerSurface(player: state.player)
                    .aspectRatio(CGFloat(max(capture.width, 1)) / CGFloat(max(capture.height, 1)), contentMode: .fit)
                if !state.playing || hovering {
                    Button { state.toggle() } label: {
                        Image(systemName: state.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(hex: 0x1A1915))
                            .offset(x: state.playing ? 0 : 2)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Theme.ivory.opacity(0.94)))
                            .shadow(color: .black.opacity(0.28), radius: 16, y: 12)
                    }
                    .buttonStyle(PressStyle())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .onHover { hovering = $0 }
            .animation(Theme.fade, value: state.playing)
            .animation(Theme.fade, value: hovering)
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                if !frames.isEmpty { strip }
                scrubber
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task(id: capture.id) { frames = await Self.frames(of: capture) }
        .onDisappear { state.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .commonPlaceSpace)) { _ in state.toggle() }
    }

    private var times: [Double] { MediaImporter.keyTimes(duration: state.duration, count: frames.count) }

    private var strip: some View {
        let current = times.lastIndex { $0 <= state.time + 0.05 } ?? 0
        return HStack(spacing: 6) {
            ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                Button { state.seek(times[index]) } label: {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.ivory, lineWidth: index == current ? 2 : 0))
                        .opacity(index == current ? 1 : 0.55)
                }
                .buttonStyle(PressStyle())
            }
        }
        .animation(Theme.fade, value: current)
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Text(Self.clock(state.time)).font(Theme.figures(10.5)).foregroundStyle(Theme.ivory.opacity(0.72))
            GeometryReader { geometry in
                let progress = CGFloat(state.time / state.duration)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ivory.opacity(0.18)).frame(height: 2)
                    Capsule().fill(Theme.ivory).frame(width: max(0, geometry.size.width * progress), height: 2)
                    Circle().fill(Theme.ivory).frame(width: 10, height: 10)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: geometry.size.width * progress - 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    state.seek(Double(drag.location.x / max(geometry.size.width, 1)) * state.duration)
                })
            }
            .frame(height: 16)
            Text(Self.clock(state.duration)).font(Theme.figures(10.5)).foregroundStyle(Theme.ivory.opacity(0.72))
        }
    }

    static func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds.isFinite ? seconds : 0).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// The contact sheet cut back into its frames.
    static func frames(of capture: Capture) async -> [NSImage] {
        let url = AppModel.shared.store.sheetURL(capture.id)
        return await Task.detached {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let cells = ContactSheet.cells(width: sheet.width, height: sheet.height) else { return [] }
            return cells.compactMap { sheet.cropping(to: $0) }.map { NSImage(cgImage: $0, size: .zero) }
        }.value
    }
}

/// AVPlayer's picture without its controls (the stage draws its own).
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.cornerRadius = 6
        layer.masksToBounds = true
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}

// MARK: - The words

private struct WordsPane: View {
    let capture: Capture
    @ObservedObject private var model = AppModel.shared
    /// The note being written, and the capture it belongs to.
    @State private var note = ""
    @State private var noteID: String?
    @State private var savedNote = false
    @State private var newTag = ""
    @State private var related: [Capture] = []
    @State private var showText = false
    @State private var showTranscript = false
    @State private var copied: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topRow.padding(.horizontal, 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(capture.displayTitle)
                        .font(Theme.serif(34))
                        .kerning(-0.6)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 24)
                    if let summary = capture.summary, !summary.isEmpty {
                        Text(summary)
                            .font(Theme.sans(14))
                            .lineSpacing(8)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 16)
                    }
                    if capture.stage != .organized { reading.padding(.top, 16) }
                    if !capture.highlights.isEmpty { highlights }
                    if let transcript = capture.transcript, !transcript.isEmpty { said(transcript) }
                    filing
                    noteField
                    if !capture.links.isEmpty { links }
                    if let text = capture.ocrText, !text.isEmpty { screenText(text) }
                    if !related.isEmpty { nearIt }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
                .id(capture.id)
                .transition(.opacity)
            }
            .scrollIndicators(.never)
            footer.padding(.horizontal, 32)
        }
        .animation(Theme.fade, value: capture.id)
        .task(id: capture.id) {
            // Browsing on: the note written for the last one is kept first.
            saveNote()
            note = capture.note ?? ""
            noteID = capture.id
            showTranscript = false
            related = Array(await model.related(to: capture.id).prefix(4))
        }
        .onChange(of: capture.stage) { _, _ in
            Task { related = Array(await model.related(to: capture.id).prefix(4)) }
        }
        .onDisappear { saveNote() }
    }

    // MARK: Parts

    private var topRow: some View {
        HStack(spacing: 8) {
            Caption(kept)
            Spacer()
            Button { model.toggleFavorite(capture) } label: {
                Image(systemName: capture.favorite ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(capture.favorite ? Theme.accent : Theme.ink2)
                    .symbolEffect(.bounce, value: capture.favorite)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help(capture.favorite ? "Remove from Favorites (F)" : "Add to Favorites (F)")
            Menu {
                CaptureMenu(capture: capture)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { withAnimation(Theme.spring) { model.selectedID = nil } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.wash))
            }
            .buttonStyle(PressStyle())
            .help("Close (esc)")
        }
        .frame(height: 64)
    }

    /// "Kept today · 20:09", "Kept 13 Oct · 20:09".
    private var kept: String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(capture.createdAt) ? "today"
            : calendar.isDateInYesterday(capture.createdAt) ? "yesterday"
            : capture.createdAt.formatted(.dateTime.day().month(.abbreviated))
        return "Kept \(day) · \(capture.createdAt.formatted(date: .omitted, time: .shortened))"
    }

    private var reading: some View {
        HStack(spacing: 8) {
            if capture.lastError == nil { Working() } else { Circle().fill(Theme.ink4).frame(width: 6, height: 6) }
            Caption(capture.lastError == nil ? "Reading what this is" : "Waiting for Ollama to read it",
                    color: capture.lastError == nil ? Theme.accent : Theme.ink3)
        }
    }

    private var highlights: some View {
        section("Worth keeping") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(capture.highlights, id: \.self) { passage in
                    Text("“\(passage)”")
                        .font(Theme.serif(20, italic: true))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func said(_ transcript: String) -> some View {
        section("Said in it", mark: AnyView(Squiggle())) {
            VStack(alignment: .leading, spacing: 8) {
                Text("“\(transcript)”")
                    .font(Theme.serif(20, italic: true))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(showTranscript ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if transcript.count > 220 {
                    Button(showTranscript ? "Less" : "All of it") { withAnimation(Theme.spring) { showTranscript.toggle() } }
                        .buttonStyle(.plain)
                        .font(Theme.sans(12.5, .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    /// Its collection (a menu to move it) and its tags.
    private var filing: some View {
        section("In") {
            FlowLayout(spacing: 8) {
                Menu {
                    ForEach(model.collections) { collection in
                        Button(collection.name) { model.move(capture.id, to: collection.id) }
                    }
                    Divider()
                    Button("No Collection") { model.move(capture.id, to: nil) }
                } label: {
                    // Words only: a menu's label is drawn by AppKit, which
                    // ignores a picture's frame (a cover came out full size).
                    Text(model.collection(capture.collectionID)?.name
                         ?? (capture.stage == .organized ? "Unsorted" : "Filing…"))
                        .font(Theme.sans(12.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().strokeBorder(Theme.ink.opacity(0.85), lineWidth: 1))
                .help("Move to another collection")

                ForEach(capture.tags, id: \.self) { tag in
                    TagChip(tag: tag) { model.setTags(capture.id, capture.tags.filter { $0 != tag }) }
                }
                TextField("", text: $newTag, prompt: Text("+ tag").foregroundColor(Theme.ink3))
                    .textFieldStyle(.plain)
                    .font(Theme.sans(12.5))
                    .frame(width: 72, height: 28)
                    .padding(.horizontal, 10)
                    .overlay(Capsule().strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .onSubmit {
                        let tag = LibraryStore.normalizedTag(newTag)
                        if !tag.isEmpty, !capture.tags.contains(tag) { model.setTags(capture.id, capture.tags + [tag]) }
                        newTag = ""
                    }
            }
        }
    }

    private var noteField: some View {
        section("Your note") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: $note, prompt: Text("Why you kept it").foregroundColor(Theme.ink4), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.serif(19))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...6)
                    .focused($noteFocused)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(noteFocused ? Theme.accent : Theme.hairline).frame(height: 1)
                    }
                    .onSubmit { saveNote() }
                    .onChange(of: noteFocused) { _, focused in if !focused { saveNote() } }
                Caption("Saved", color: Theme.accent)
                    .opacity(savedNote ? 1 : 0)
                    .animation(Theme.fade, value: savedNote)
            }
            .animation(Theme.fade, value: noteFocused)
        }
    }

    private var links: some View {
        section("Links") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(capture.links, id: \.self) { link in
                    if let url = URL(string: link) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Text(url.host ?? link).font(Theme.sans(13)).foregroundStyle(Theme.ink)
                                Text(url.path.count > 1 ? url.path : "").font(Theme.sans(13)).foregroundStyle(Theme.ink3)
                                    .lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
                            }
                        }
                    }
                }
            }
        }
    }

    private func screenText(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { withAnimation(Theme.spring) { showText.toggle() } } label: {
                    HStack(spacing: 6) {
                        Caption("Text on the screen")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Theme.ink4)
                            .rotationEffect(.degrees(showText ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                copyButton("Copy", text)
            }
            if showText {
                Text(text)
                    .font(Theme.figures(11.5))
                    .foregroundStyle(Theme.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.top, 32)
    }

    private var nearIt: some View {
        section("Near it") {
            HStack(alignment: .top, spacing: 8) {
                ForEach(related) { other in
                    Button { withAnimation(Theme.spring) { model.selectedID = other.id } } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Thumbnail(capture: other)
                                .frame(height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                            Text(other.displayTitle)
                                .font(Theme.sans(12))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
                ForEach(0..<max(0, 4 - related.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
            }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(hints: true)
            footerRow(hints: false)
        }
        .frame(height: 56)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func footerRow(hints: Bool) -> some View {
        HStack(spacing: 4) {
            if let url = capture.url.flatMap(URL.init(string:)) {
                Button("Open page ↗") { NSWorkspace.shared.open(url) }.buttonStyle(GhostButton())
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.originalURL(capture) ?? model.imageURL(capture)]) }
                .buttonStyle(GhostButton())
            Button(copied == "image" ? "Copied" : "Copy image") {
                if model.copyImage(capture) { flash("image") }
            }
            .buttonStyle(GhostButton())
            Spacer(minLength: 8)
            if hints {
                HStack(spacing: 4) {
                    KeyCap("←")
                    KeyCap("→")
                    Text("browse").font(Theme.sans(12)).foregroundStyle(Theme.ink4).padding(.trailing, 8).padding(.leading, 4)
                    KeyCap("esc")
                    Text("close").font(Theme.sans(12)).foregroundStyle(Theme.ink4).padding(.leading, 4)
                }
                .fixedSize()
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, mark: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let mark { mark }
                Caption(title)
            }
            content()
        }
        .padding(.top, 32)
    }

    private func copyButton(_ title: String, _ text: String) -> some View {
        Button(copied == text ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            flash(text)
        }
        .buttonStyle(.plain)
        .font(Theme.sans(12, .medium))
        .foregroundStyle(copied == text ? Theme.accent : Theme.ink2)
    }

    private func flash(_ what: String) {
        withAnimation(Theme.fade) { copied = what }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(Theme.fade) { if copied == what { copied = nil } }
        }
    }

    /// The note, stored for the capture it was written for, when it changed.
    private func saveNote() {
        guard let id = noteID else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = ((try? model.store.capture(id))??.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != stored else { return }
        model.setNote(id, trimmed)
        savedNote = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { savedNote = false }
    }
}

/// A tag; its × shows on hover.
private struct TagChip: View {
    let tag: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tag).font(Theme.sans(12.5)).foregroundStyle(Theme.ink2)
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .overlay(Capsule().strokeBorder(Theme.hairline.opacity(1.25)))
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering)
    }
}

/// A short wave in the accent: something was said.
private struct Squiggle: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 2, y: 8.5))
            path.addCurve(to: CGPoint(x: 5, y: 8.5), control1: CGPoint(x: 3.2, y: 5.5), control2: CGPoint(x: 4.2, y: 5.5))
            path.addCurve(to: CGPoint(x: 8, y: 8.5), control1: CGPoint(x: 5.8, y: 11.5), control2: CGPoint(x: 6.8, y: 11.5))
            path.addCurve(to: CGPoint(x: 11, y: 8.5), control1: CGPoint(x: 9.2, y: 5.5), control2: CGPoint(x: 10.2, y: 5.5))
            path.addCurve(to: CGPoint(x: 14, y: 8.5), control1: CGPoint(x: 11.8, y: 11.5), control2: CGPoint(x: 12.8, y: 11.5))
        }
        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        .frame(width: 16, height: 16)
    }
}

/// Tags wrapped onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Quick Look for a capture's full image.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    private static let shared = QuickLook()
    private var url: URL?

    static func show(_ url: URL) {
        shared.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
