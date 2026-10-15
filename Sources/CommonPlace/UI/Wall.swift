import AppKit
import CommonPlaceKit
import SwiftUI

/// A capture's small picture (its thumbnail), filling whatever frame it is given.
struct Thumbnail: View {
    let capture: Capture
    var full = false
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                if let image = model.image(for: capture, full: full) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Theme.well
                }
            }
            .clipped()
    }
}

/// The wall of a shelf: its tabs (all, screens, photos, videos), the time
/// it covers, and the cards.
struct WallSection: View {
    let title: String
    @ObservedObject private var model = AppModel.shared
    @Namespace private var underline

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 24) {
                Caption(title)
                    .padding(.trailing, 8)
                tabs
                Spacer()
                timeMenu
            }
            .frame(height: 32)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            let shown = model.shown
            if shown.isEmpty {
                EmptyShelf(filtered: model.mediaFilter != nil || model.timeFilter != nil)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            } else {
                MasonryLayout(columnWidth: 240, spacing: 24) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, capture in
                        CaptureCard(capture: capture, order: index)
                    }
                }
                .animation(Theme.spring, value: shown.map(\.id))
            }
        }
    }

    private var tabs: some View {
        let counts = model.shelfMediaCounts
        let options: [CaptureMedia?] = [nil] + CaptureMedia.allCases.filter { (counts[$0] ?? 0) > 0 }
        return HStack(spacing: 24) {
            ForEach(options, id: \.self) { media in
                let selected = model.mediaFilter == media
                Button {
                    withAnimation(Theme.spring) { model.mediaFilter = media }
                } label: {
                    HStack(spacing: 6) {
                        Text(media?.title ?? "All")
                            .font(Theme.sans(13, selected ? .medium : .regular))
                            .foregroundStyle(selected ? Theme.ink : Theme.ink3)
                        if let media {
                            Text("\(counts[media] ?? 0)")
                                .font(Theme.figures(10.5))
                                .foregroundStyle(Theme.ink4)
                        }
                    }
                    .frame(height: 32)
                    .overlay(alignment: .bottom) {
                        if selected {
                            Rectangle().fill(Theme.ink).frame(height: 1.5)
                                .matchedGeometryEffect(id: "underline", in: underline)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
    }

    private var timeMenu: some View {
        Menu {
            Button("Any time") { withAnimation(Theme.spring) { model.timeFilter = nil } }
            Divider()
            ForEach(TimeShelf.allCases, id: \.self) { shelf in
                Button(shelf.title) { withAnimation(Theme.spring) { model.timeFilter = shelf } }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.timeFilter?.title ?? "Any time").font(Theme.sans(13))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(model.timeFilter == nil ? Theme.ink2 : Theme.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Nothing on the wall: what to do about it, in the collage's language.
struct EmptyShelf: View {
    var filtered = false

    var body: some View {
        VStack(spacing: 20) {
            ArtPiece(name: "empty", width: filtered ? 200 : 320)
            if filtered {
                headline("Nothing here", "for now.", size: 32).foregroundStyle(Theme.ink)
                Caption("Try all kinds, or any time")
            } else {
                headline("Nothing kept", "here yet.", size: 32).foregroundStyle(Theme.ink)
                HStack(spacing: 8) {
                    Text("Press").font(Theme.sans(13)).foregroundStyle(Theme.ink2)
                    CaptureKeysView()
                    Text("on anything worth keeping.").font(Theme.sans(13)).foregroundStyle(Theme.ink2)
                }
            }
        }
        .padding(.vertical, 48)
    }
}

/// Columns of cards, each placed in the shortest column (a masonry wall).
struct MasonryLayout: Layout {
    var columnWidth: CGFloat
    var spacing: CGFloat

    /// SwiftUI also asks for sizes at an infinite or zero width (ideal
    /// sizing): those are laid out at one column of `columnWidth`, never
    /// converted to an Int (an infinite width crashed the window).
    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        guard width.isFinite, width >= columnWidth else { return (1, width.isFinite && width > 0 ? width : columnWidth) }
        let count = max(1, Int((width + spacing) / (columnWidth + spacing)))
        return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    private func placements(_ width: CGFloat, _ subviews: Subviews) -> ([CGPoint], CGFloat, CGFloat) {
        let (count, column) = columns(for: width)
        var heights = [CGFloat](repeating: 0, count: count)
        var points: [CGPoint] = []
        for view in subviews {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = view.sizeThatFits(ProposedViewSize(width: column, height: nil))
            points.append(CGPoint(x: CGFloat(shortest) * (column + spacing), y: heights[shortest]))
            heights[shortest] += size.height + spacing
        }
        return (points, column, max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? columnWidth
        return CGSize(width: width, height: placements(width, subviews).2)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (points, column, _) = placements(bounds.width, subviews)
        for (view, point) in zip(subviews, points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                       proposal: ProposedViewSize(width: column, height: nil))
        }
    }
}

/// One capture on the wall: its picture at its own shape, its title, and a
/// mono line of what it is and where it came from.
struct CaptureCard: View {
    let capture: Capture
    /// Its place on the wall: the first cards arrive one after another.
    var order = 0
    @ObservedObject private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picture
            Text(capture.displayTitle)
                .font(Theme.sans(13.5, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            meta.padding(.top, 4)
        }
        .contentShape(Rectangle())
        .offset(y: hovering && !reduceMotion ? -2 : 0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 10)
        .onAppear {
            guard !appeared else { return }
            withAnimation(Theme.spring.delay(reduceMotion ? 0 : min(Double(order), 16) * 0.025)) { appeared = true }
        }
        .onHover { inside in
            hovering = inside
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onDisappear { if hovering { NSCursor.arrow.set() } }
        .animation(Theme.snappy, value: hovering)
        .onTapGesture { withAnimation(Theme.spring) { model.selectedID = capture.id } }
        .contextMenu { CaptureMenu(capture: capture) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The picture at the capture's own shape (kept between portrait and
    /// wide), top-anchored: a page's title and heading are at its top.
    private var picture: some View {
        let ratio = CGFloat(max(capture.width, 1)) / CGFloat(max(capture.height, 1))
        return Color.clear
            .aspectRatio(min(max(ratio, 0.75), 1.9), contentMode: .fit)
            .overlay(alignment: .top) {
                if let image = model.image(for: capture) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(hovering && !reduceMotion ? 1.03 : 1, anchor: .top)
                } else {
                    Theme.well
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: Theme.shadow.opacity(hovering ? 0.12 : 0), radius: 16, y: 10)
            .overlay(alignment: .bottomLeading) { durationBadge }
            .overlay(alignment: .topTrailing) { favoriteBadge }
            .overlay {
                if capture.stage != .organized && capture.lastError == nil { ReadingShimmer() }
            }
    }

    private var meta: some View {
        HStack(spacing: 0) {
            if capture.stage != .organized {
                Caption(capture.lastError == nil ? "Reading" : "Waiting for Ollama",
                        color: capture.lastError == nil ? Theme.accent : Theme.ink4)
            } else {
                Caption([capture.kind?.title, capture.sourceName].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if capture.media == .video, let duration = capture.duration {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 6))
                Text(Duration.seconds(duration).formatted(.time(pattern: duration >= 3_600 ? .hourMinuteSecond : .minuteSecond)))
                    .font(Theme.figures(10.5))
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .frame(height: 20)
            .background(Capsule().fill(.ultraThinMaterial))
            .background(Capsule().fill(Theme.surface.opacity(0.7)))
            .padding(8)
        }
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if capture.favorite {
            Image(systemName: "star.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.surface.opacity(0.92)))
                .padding(8)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// A slow band of light across a picture still being read.
private struct ReadingShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [.clear, Theme.surface.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 0.6)
                .offset(x: phase * geometry.size.width * 1.6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// The right-click menu of a capture (on a card and in the detail).
struct CaptureMenu: View {
    let capture: Capture
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Button(capture.favorite ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(capture) }
        if let url = capture.url.flatMap(URL.init(string:)) {
            Button("Open \(capture.sourceName)") { NSWorkspace.shared.open(url) }
        }
        Menu("Move to Collection") {
            ForEach(model.collections) { collection in
                Button(collection.name) { model.move(capture.id, to: collection.id) }
            }
            Divider()
            Button("No Collection") { model.move(capture.id, to: nil) }
        }
        Button("Copy Image") { model.copyImage(capture) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.imageURL(capture)]) }
        Divider()
        Button("Delete", role: .destructive) { withAnimation(Theme.spring) { model.delete(capture.id) } }
    }
}
