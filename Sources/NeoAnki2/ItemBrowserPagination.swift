import Foundation

/// Keeps SwiftUI's macOS table diff bounded. `Table` bridges every row through
/// hosted AppKit views, and reconciling an entire large library at once can
/// spend minutes tearing those views down on the main thread.
struct ItemBrowserPagination: Equatable {
    static let defaultPageSize = 500

    let itemCount: Int
    let pageSize: Int
    let pageCount: Int
    let pageIndex: Int
    let itemRange: Range<Int>

    init(
        itemCount: Int,
        requestedPageIndex: Int,
        pageSize: Int = defaultPageSize
    ) {
        let boundedItemCount = max(0, itemCount)
        let boundedPageSize = max(1, pageSize)
        let calculatedPageCount = max(
            1,
            (boundedItemCount + boundedPageSize - 1) / boundedPageSize
        )
        let boundedPageIndex = min(max(0, requestedPageIndex), calculatedPageCount - 1)
        let lowerBound = min(boundedItemCount, boundedPageIndex * boundedPageSize)
        let upperBound = min(boundedItemCount, lowerBound + boundedPageSize)

        self.itemCount = boundedItemCount
        self.pageSize = boundedPageSize
        pageCount = calculatedPageCount
        pageIndex = boundedPageIndex
        itemRange = lowerBound..<upperBound
    }

    var hasMultiplePages: Bool {
        pageCount > 1
    }

    var canGoBackward: Bool {
        pageIndex > 0
    }

    var canGoForward: Bool {
        pageIndex + 1 < pageCount
    }

    var previousPageIndex: Int {
        max(0, pageIndex - 1)
    }

    var nextPageIndex: Int {
        min(pageCount - 1, pageIndex + 1)
    }

    var firstItemNumber: Int {
        itemRange.isEmpty ? 0 : itemRange.lowerBound + 1
    }

    var lastItemNumber: Int {
        itemRange.upperBound
    }
}
