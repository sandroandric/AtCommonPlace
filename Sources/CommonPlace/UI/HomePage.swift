import AppKit
import CommonPlaceKit
import SwiftUI

/// Home: the day as a collage (paper, the sky at this hour with the day's
/// headline, the last thing kept), the largest collections, and the wall.
struct HomePage: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HeroCollage()
            if !model.collections.isEmpty { CollectionSpreads() }
            WallSection(title: "Recently")
        }
    }
}

/// Three hard-cut panels side by side, like a launch film's opening frame.
private struct HeroCollage: View {
    @ObservedObject private var model = AppModel.shared
    @State private var hoveringLatest = false

    var body: some View {
        GeometryReader { geometry in
            let roomy = geometry.size.width >= 900
            HStack(spacing: 0) {
                if roomy {
                    // Torn, and laid a little over the sky, like pasted paper.
                    PaperPanel()
                        .clipShape(TornEdge())
                        .shadow(color: .black.opacity(0.35), radius: 3, x: 2)
                        .frame(width: 286)
                        .padding(.trailing, -6)
                        .zIndex(1)
                }
                TimelineView(.everyMinute) { context in
                    sky(at: context.date)
                }
                latest.frame(width: roomy ? 280 : 240)
            }
        }
        .frame(height: 216)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: Theme.shadow.opacity(0.08), radius: 24, y: 24)
    }

    private func sky(at date: Date) -> some View {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let phase = SkyPhase.at(hour: hour, minute: calendar.component(.minute, from: date))
        let today = Wording.today(kept: model.timeCounts[.today] ?? 0, hour: hour)
        let text = Horizon.text(phase)
        return ZStack {
            Horizon(phase: phase)
            VStack(spacing: 0) {
                Caption(date.formatted(.dateTime.weekday(.wide).day().month(.wide)), color: text.opacity(0.62))
                    .padding(.top, 20)
                Spacer()
                headline(today.lead, today.close, size: 42)
                    .kerning(-0.7)
                    .foregroundStyle(text)
                    .shadow(color: Color(hex: 0xE0561F).opacity(phase == .day || phase == .morning ? 0 : 0.35), radius: 12)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 24)
                    .contentTransition(.numericText())
                Spacer().frame(height: 46)
                Text("\(model.total) in all · \(Wording.count(model.collections.count, "collection", "collections", capitalized: false))")
                    .font(Theme.sans(12))
                    .foregroundStyle(text.opacity(0.5))
                    .padding(.bottom, 16)
            }
        }
        .animation(Theme.spring, value: model.timeCounts[.today])
    }

    /// The newest capture, warmed and grained; it opens on a click.
    @ViewBuilder
    private var latest: some View {
        if let newest = model.newest {
            Button {
                withAnimation(Theme.spring) { model.selectedID = newest.id }
            } label: {
                ZStack(alignment: .bottomLeading) {
                    Theme.stage
                    Thumbnail(capture: newest, full: true)
                        .saturation(1.18)
                        .contrast(1.12)
                        .scaleEffect(hoveringLatest ? 1.05 : 1)
                        .animation(.easeOut(duration: 1.6), value: hoveringLatest)
                    Grain(tone: .light, opacity: 0.42)
                    LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                    Caption("Latest · \(newest.createdAt.shortRelative)", color: Theme.ivory.opacity(0.85))
                        .padding(16)
                }
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringLatest = $0 }
            .id(newest.id)
            .transition(.opacity)
        } else {
            ZStack {
                Theme.stage
                Grain(tone: .light, opacity: 0.42)
                BrandMark(size: 44, onDark: true)
            }
        }
    }
}

/// The largest collections as spreads: one picture large, two small.
private struct CollectionSpreads: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        let shown = Array(model.collections.sorted { $0.count > $1.count }.prefix(4))
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Caption("Collections")
                Spacer()
                Caption(Wording.count(model.collections.count, "collection", "collections", capitalized: false))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 400), spacing: 24, alignment: .top)],
                      alignment: .leading, spacing: 24) {
                ForEach(shown) { collection in
                    CollectionSpread(collection: collection, covers: model.covers[collection.id] ?? [])
                }
            }
        }
    }
}

private struct CollectionSpread: View {
    let collection: CaptureCollection
    let covers: [Capture]
    @ObservedObject private var model = AppModel.shared
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Theme.spring) { model.shelf = .collection(collection.id) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { geometry in
                    let gap: CGFloat = hovering ? 6 : 4
                    let small = (geometry.size.width - gap) * 0.33
                    HStack(spacing: gap) {
                        cover(0)
                        VStack(spacing: gap) {
                            cover(1)
                            cover(2)
                        }
                        .frame(width: small)
                    }
                }
                .frame(height: 152)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: Theme.shadow.opacity(hovering ? 0.1 : 0), radius: 16, y: 10)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(collection.name)
                        .font(Theme.serif(18))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(String(format: "%02d", collection.count))
                        .font(Theme.figures(10.5))
                        .foregroundStyle(Theme.ink4)
                }
                .padding(.top, 12)
                Text(Self.updated(collection.updatedAt))
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering)
    }

    /// "Updated today", "Updated yesterday", "Updated 13 Oct".
    static func updated(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Updated today" }
        if calendar.isDateInYesterday(date) { return "Updated yesterday" }
        return "Updated " + date.formatted(.dateTime.day().month(.abbreviated))
    }

    @ViewBuilder
    private func cover(_ index: Int) -> some View {
        if covers.indices.contains(index) {
            Thumbnail(capture: covers[index]).scaleEffect(hovering ? 1.04 : 1)
                .clipped()
        } else {
            Theme.well
        }
    }
}

/// Any other shelf: what it is in a caption, its name in serif, the wall.
struct ShelfPage: View {
    @ObservedObject private var model = AppModel.shared
    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Caption("\(kindOfShelf) · \(Wording.count(model.captures.count, "thing", "things", capitalized: false))")
                    Text(model.shelfTitle)
                        .font(Theme.serif(48))
                        .kerning(-1.0)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Spacer()
                if case .collection = model.shelf {
                    Button("Rename") { renaming = true }.buttonStyle(GhostButton())
                }
            }
            .padding(.top, 24)
            WallSection(title: model.shelf == .favorites ? "Favorites" : "Kept")
        }
        .sheet(isPresented: $renaming) {
            if case .collection(let id) = model.shelf, let collection = model.collection(id) {
                RenameCollectionSheet(collection: collection)
            }
        }
    }

    private var kindOfShelf: String {
        switch model.shelf {
        case .recent: return "Home"
        case .favorites: return "Favorites"
        case .unsorted: return "Waiting for something like it"
        case .collection: return "Collection"
        case .kind: return "Kind"
        case .source: return "From"
        }
    }
}
