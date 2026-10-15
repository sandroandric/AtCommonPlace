import Foundation

/// Search by meaning (the query's EmbeddingGemma 2 vector against each
/// capture's look and meaning vectors) and by words (FTS5), merged by
/// reciprocal rank: a capture several of them find ranks first.
public enum SearchMerge {
    /// A hit stands out when it is this far above the query's median score...
    public static let aboveMedian: Float = 0.08
    /// ...and this close to its best hit.  Chosen by precision and recall on
    /// 20 labelled queries over 38 real captures (measured with cp-eval): a
    /// fixed floor cannot work (a right answer scored 0.656 for one query, a
    /// wrong one 0.644 for another).
    public static let nearTop: Float = 0.07
    /// A collection is completed in the results when this share of its
    /// members (and at least `completionMinimum`) was found: "space
    /// exploration" found 3 of the 4 NASA Space Missions, Apollo 11 scored
    /// 0.002 under the floor.
    public static let completionShare: Double = 0.75
    public static let completionMinimum = 3
    static let k: Double = 60

    /// Of `scores` (one query against every capture), the stand-outs, best first.
    public static func standouts(_ scores: [(id: String, score: Float)]) -> [(id: String, score: Float)] {
        guard !scores.isEmpty else { return [] }
        let sorted = scores.sorted { $0.score > $1.score }
        let values = sorted.map(\.score)
        let median = values[values.count / 2]
        let top = values[0]
        // With only a few captures the median is no background: then the top's margin alone.
        let floor = values.count >= 6 ? max(median + aboveMedian, top - nearTop) : top - nearTop
        return sorted.filter { $0.score >= floor }
    }

    /// Ranked id lists merged: each list adds 1 / (k + rank).
    public static func merge(_ lists: [[String]], limit: Int = 60) -> [String] {
        var fused: [String: Double] = [:]
        for list in lists {
            for (position, id) in list.enumerated() {
                fused[id, default: 0] += 1 / (k + Double(position + 1))
            }
        }
        return fused.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }

    /// The collections `found` mostly covers (by id, in id order).
    /// `members`: collection id → member ids.
    public static func coveredCollections(_ found: [String], members: [String: [String]]) -> [String] {
        let hits = Set(found)
        return members.sorted(by: { $0.key < $1.key }).compactMap { id, ids in
            guard ids.count >= completionMinimum else { return nil }
            let covered = ids.filter(hits.contains).count
            return Double(covered) / Double(ids.count) >= completionShare ? id : nil
        }
    }

    /// `found` (ranked) followed by the rest of each collection it mostly
    /// covers.  `members`: collection id → member ids.
    public static func completingCollections(_ found: [String], members: [String: [String]]) -> [String] {
        let hits = Set(found)
        var result = found
        for id in coveredCollections(found, members: members) {
            result += (members[id] ?? []).filter { !hits.contains($0) && !result.contains($0) }
        }
        return result
    }

    /// Why each id came up: the lists that found it, and `.collection` for
    /// one only added to complete its collection.
    public static func reasons(_ lists: [SearchReason: [String]], completed: [String]) -> [String: Set<SearchReason>] {
        var reasons: [String: Set<SearchReason>] = [:]
        for (reason, ids) in lists {
            for id in ids { reasons[id, default: []].insert(reason) }
        }
        for id in completed where reasons[id] == nil { reasons[id] = [.collection] }
        return reasons
    }

    /// Every capture's score against `vector`.
    public static func scores(_ vector: [Float], in vectors: [(id: String, vector: [Float])],
                              excluding: String? = nil) -> [(id: String, score: Float)] {
        vectors.filter { $0.id != excluding }.map { ($0.id, VectorMath.dot(vector, $0.vector)) }
    }
}

/// What found a search result.
public enum SearchReason: String, CaseIterable, Sendable, Hashable {
    /// Its words (titles, summary, text on the screen, notes, what was said).
    case words
    /// Its picture and window, by the query's meaning.
    case look
    /// What it is about: its title, topics and note.
    case meaning
    /// Not found itself: the rest of a collection the search mostly found.
    case collection

    /// The space each vector list searches.
    public init(_ space: VectorSpace) {
        switch space {
        case .look: self = .look
        case .meaning: self = .meaning
        }
    }
}

/// One search result and why it came up.
public struct SearchHit: Sendable, Identifiable {
    public let capture: Capture
    public let reasons: Set<SearchReason>
    public var id: String { capture.id }

    public init(capture: Capture, reasons: Set<SearchReason>) {
        self.capture = capture
        self.reasons = reasons
    }
}

/// What one search found: the hits, best first, and the collections they
/// mostly cover.
public struct SearchFindings: Sendable {
    public let hits: [SearchHit]
    public let collectionIDs: [String]

    public init(hits: [SearchHit], collectionIDs: [String]) {
        self.hits = hits
        self.collectionIDs = collectionIDs
    }
}
