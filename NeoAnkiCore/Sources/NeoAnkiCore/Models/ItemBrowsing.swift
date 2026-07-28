import Foundation

/// Search and ordering for browsed item lists.
///
/// Lives beside the model rather than in the store so a client can re-sort a
/// list it already holds — a table header click should not require a new query.
public enum ItemBrowsing {
    public static func arrange(
        _ items: [SavedItemSummary],
        sort: ItemSortOrder = .createdAscending,
        search: String = ""
    ) -> [SavedItemSummary] {
        let matched = filter(items, search: search)
        return matched.sorted { isOrdered($0, before: $1, by: sort) }
    }

    public static func filter(_ items: [SavedItemSummary], search: String) -> [SavedItemSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { matches($0, query: query) }
    }

    /// Matches the prompt, the answer, and the item type name. The answer is
    /// searchable even though browsing keeps it hidden — finding an item you
    /// half-remember is the whole point.
    public static func matches(_ item: SavedItemSummary, query: String) -> Bool {
        contains(item.title, query)
            || contains(item.subtitle, query)
            || contains(item.itemTypeName, query)
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    /// Every order falls back to creation time and then identifier, so a list
    /// never reshuffles between two reloads of unchanged data.
    private static func isOrdered(
        _ lhs: SavedItemSummary,
        before rhs: SavedItemSummary,
        by sort: ItemSortOrder
    ) -> Bool {
        switch sort {
        case .createdAscending:
            break
        case .createdDescending:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        case .titleAscending:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .dueSoonest:
            // Unscheduled items sort last: they have nothing to answer for.
            switch (lhs.schedule?.dueAt, rhs.schedule?.dueAt) {
            case let (left?, right?) where left != right:
                return left < right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                break
            }
        }

        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
