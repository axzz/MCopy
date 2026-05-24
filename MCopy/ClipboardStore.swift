import Foundation
import SwiftData

/// LRU-style storage for `ClipboardItem`.
///
/// Recency is encoded in `timestamp` (descending = most-recently-used first),
/// so the existing `@Query(sort: \.timestamp, order: .reverse)` in the UI
/// reflects LRU order without further changes.
///
/// Capacity is enforced on every mutation: items past `capacity` are deleted.
final class ClipboardStore {
    static let capacity = 20

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Insert a new clipboard item at the front. If an entry with identical
    /// content already exists in history, it is touched (moved to the front)
    /// instead of duplicated. Evicts oldest entries beyond capacity.
    @discardableResult
    func insert(_ item: ClipboardItem) -> ClipboardItem {
        let existing = (try? modelContext.fetch(
            FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        )) ?? []

        if let dup = findDuplicate(of: item, in: existing) {
            // Latest formatting wins: the user re-copied the same text, possibly
            // from a richer source (e.g. plain copy from Terminal, then styled
            // copy from Word). Refresh the rich-text payloads so paste uses the
            // most recent fidelity rather than whatever was captured first.
            if dup.type == .text {
                dup.rtfData = item.rtfData
                dup.htmlData = item.htmlData
            }
            touch(dup)
            return dup
        }
        modelContext.insert(item)
        // The new item just took one slot; everything past (capacity - 1) in
        // the pre-insert list is now over capacity.
        let surviveCount = Self.capacity - 1
        if existing.count > surviveCount {
            for stale in existing[surviveCount...] {
                modelContext.delete(stale)
            }
        }
        try? modelContext.save()
        return item
    }

    /// Mark `item` as most-recently-used: update its timestamp to now so it
    /// surfaces at the front of the timestamp-descending query.
    func touch(_ item: ClipboardItem) {
        item.timestamp = Date()
        try? modelContext.save()
    }

    private func findDuplicate(of item: ClipboardItem, in existing: [ClipboardItem]) -> ClipboardItem? {
        existing.first { candidate in
            guard candidate.contentType == item.contentType,
                  candidate.textContent == item.textContent else { return false }
            // Compare on the small thumbnail when present — raw image data is
            // tens of MB per screenshot and byte-comparison is O(size).
            let lhs = item.thumbnailData ?? item.imageData
            let rhs = candidate.thumbnailData ?? candidate.imageData
            return lhs == rhs
        }
    }
}
