import Foundation
import Testing

@testable import NeoAnki2

@Test func deckDragPayloadUsesASystemTransferType() {
    let provider = DeckDragPayload.itemProvider(for: UUID())

    #expect(
        provider.hasItemConformingToTypeIdentifier(
            DeckDragPayload.contentType.identifier
        )
    )
}

@Test func deckDropZonesRouteEdgesAndCenter() {
    let targetID = UUID()

    #expect(
        DeckRowDropZone.resolve(y: 2, height: 28).destination(targetID: targetID)
            == .before(targetID)
    )
    #expect(
        DeckRowDropZone.resolve(y: 14, height: 28).destination(targetID: targetID)
            == .inside(targetID)
    )
    #expect(
        DeckRowDropZone.resolve(y: 26, height: 28).destination(targetID: targetID)
            == .after(targetID)
    )
}
