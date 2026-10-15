import AppKit
import CommonPlaceKit
import SwiftUI

/// A search: the query as a headline, the collections it found whole, and
/// the things it found, numbered, with why each came up.
struct SearchPage: View {
    @ObservedObject private var model = AppModel.shared

    private var query: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let hits = model.findings?.hits ?? []
        VStack(alignment: .leading, spacing: 32) {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 12) {
                    Caption(model.searching && model.findings == nil
                            ? "Searching"
                            : "Search · by look and by meaning · \(model.searchMilliseconds) ms")
                    (Text(Wording.search(found: hits.count) + " ").font(Theme.serif(48))
                        + Text(query).font(Theme.serif(48, italic: true)).foregroundColor(Theme.accent)
                        + Text(".").font(Theme.serif(48)))
                        .kerning(-1.0)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .padding(.trailing, 176)
                    if query.lowercased() == "commonplace" {
                        // The idea is old: Locke's method was printed in English in 1706.
                        Text("John Locke published a method for keeping one in 1706.")
                            .font(Theme.serif(18, italic: true))
                            .foregroundStyle(Theme.ink3)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 4) {
                    ArtPiece(name: "lookmeaning", width: 150)
                    HStack(spacing: 0) {
                        Caption("Look", color: Theme.ink3, size: 9).frame(width: 75)
                        Caption("Meaning", color: Theme.ink3, size: 9).frame(width: 75)
                    }
                }
                .padding(.bottom, 4)
                .padding(.trailing, 8)
            }
            .padding(.top, 24)

            ForEach(model.findings?.collectionIDs ?? [], id: \.self) { id in
                if let collection = model.collection(id) {
                    WholeCollection(collection: collection, covers: model.covers[id] ?? [])
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }

            if hits.isEmpty, model.findings != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Try what it looked like, or what it was about.")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.ink2)
                    Caption("“a red bridge at sunset” · “that recipe with lemons”")
                }
            } else if !hits.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Caption("Things")
                        Spacer()
                        Caption("Why it came up")
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            ResultRow(number: index + 1, hit: hit, collection: model.collection(hit.capture.collectionID))
                        }
                    }
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
            }
        }
        .opacity(model.searching && model.findings != nil ? 0.55 : 1)
        .animation(Theme.fade, value: model.searching)
        .animation(Theme.spring, value: model.findings?.hits.map(\.id) ?? [])
    }
}

/// A collection the search found whole (or nearly).
private struct WholeCollection: View {
    let collection: CaptureCollection
    let covers: [Capture]
    @ObservedObject private var model = AppModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 24) {
            HStack(spacing: 4) {
                ForEach(Array(covers.prefix(3).enumerated()), id: \.element.id) { index, capture in
                    Thumbnail(capture: capture)
                        .frame(width: index == 0 ? 128 : 72, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Caption("The whole collection matched", color: Theme.accent)
                Text(collection.name)
                    .font(Theme.serif(32))
                    .kerning(-0.3)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(Wording.count(collection.count, "thing", "things")) in it, all about this.")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 16)
            Button("Open collection →") {
                withAnimation(Theme.spring) {
                    model.query = ""
                    model.shelf = .collection(collection.id)
                }
            }
            .buttonStyle(GhostButton())
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised.opacity(hovering ? 0.9 : 0.66)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: Theme.shadow.opacity(0.05), radius: 16, y: 12)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

private struct ResultRow: View {
    let number: Int
    let hit: SearchHit
    let collection: CaptureCollection?
    @ObservedObject private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        Button {
            withAnimation(Theme.spring) { model.selectedID = hit.capture.id }
        } label: {
            HStack(spacing: 24) {
                Text(String(format: "%02d", number))
                    .font(Theme.figures(10.5))
                    .foregroundStyle(hovering ? Theme.accent : Theme.ink4)
                    .frame(width: 24, alignment: .leading)
                Thumbnail(capture: hit.capture)
                    .frame(width: 112, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.capture.displayTitle)
                        .font(Theme.serif(20))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let summary = hit.capture.summary, !summary.isEmpty {
                        Text(summary)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                }
                .offset(x: hovering && !reduceMotion ? 4 : 0)
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(Self.why(hit.reasons, collection: collection))
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.ink)
                    Caption([hit.capture.kind?.title, hit.capture.sourceName].compactMap { $0 }.joined(separator: " · "))
                }
                .frame(width: 260, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 104)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.wash : .clear).padding(.vertical, 4))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            withAnimation(Theme.spring.delay(reduceMotion ? 0 : Double(min(number, 12)) * 0.035)) { appeared = true }
        }
        .contextMenu { CaptureMenu(capture: hit.capture) }
    }

    /// "Its look and meaning", "The words in it", "In NASA Space Missions, with the rest".
    static func why(_ reasons: Set<SearchReason>, collection: CaptureCollection?) -> String {
        if reasons == [.collection] {
            return collection.map { "In \($0.name), with the rest" } ?? "With the rest of its collection"
        }
        let parts = [(SearchReason.words, "words"), (.look, "look"), (.meaning, "meaning")]
            .filter { reasons.contains($0.0) }.map(\.1)
        switch parts.count {
        case 0: return "Close to it"
        case 1: return parts[0] == "words" ? "The words in it" : "Its \(parts[0])"
        case 2: return "Its \(parts[0]) and \(parts[1])"
        default: return "Its words, look and meaning"
        }
    }
}
