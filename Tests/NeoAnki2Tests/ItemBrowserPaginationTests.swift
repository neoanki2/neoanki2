import Testing

@testable import NeoAnki2

@Test func itemBrowserPaginationKeepsEveryTableUpdateBounded() {
    let first = ItemBrowserPagination(
        itemCount: 16_234,
        requestedPageIndex: 0
    )
    #expect(first.itemRange == 0..<500)
    #expect(first.pageCount == 33)
    #expect(first.firstItemNumber == 1)
    #expect(first.lastItemNumber == 500)
    #expect(!first.canGoBackward)
    #expect(first.canGoForward)

    let last = ItemBrowserPagination(
        itemCount: 16_234,
        requestedPageIndex: 32
    )
    #expect(last.itemRange == 16_000..<16_234)
    #expect(last.firstItemNumber == 16_001)
    #expect(last.lastItemNumber == 16_234)
    #expect(last.canGoBackward)
    #expect(!last.canGoForward)
}

@Test func itemBrowserPaginationClampsAfterFilteringOrDeletion() {
    let filtered = ItemBrowserPagination(
        itemCount: 12,
        requestedPageIndex: 32
    )
    #expect(filtered.pageIndex == 0)
    #expect(filtered.itemRange == 0..<12)
    #expect(!filtered.hasMultiplePages)

    let empty = ItemBrowserPagination(
        itemCount: 0,
        requestedPageIndex: 4
    )
    #expect(empty.pageIndex == 0)
    #expect(empty.itemRange.isEmpty)
    #expect(empty.firstItemNumber == 0)
    #expect(empty.lastItemNumber == 0)
}

@Test func itemBrowserPaginationSupportsDeterministicSmallPageTests() {
    let middle = ItemBrowserPagination(
        itemCount: 11,
        requestedPageIndex: 1,
        pageSize: 5
    )
    #expect(middle.pageCount == 3)
    #expect(middle.itemRange == 5..<10)
    #expect(middle.previousPageIndex == 0)
    #expect(middle.nextPageIndex == 2)
}
