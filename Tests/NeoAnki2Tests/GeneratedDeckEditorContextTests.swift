import Foundation
import NeoAnkiCore
import NeoAnkiSharedUI
import Testing

@Suite struct GeneratedDeckEditorContextTests {
    @Test func sourceEditorsPreserveDestinationIdentityAndOrdinaryItemsUseTheItemEditor() throws {
        var type = BuiltInItemTypes.basic
        let deckID = UUID()
        let item = Item(itemTypeID: type.id, fields: [], deckID: deckID)
        #expect(GeneratedDeckEditorContext(item: item, itemType: type) == nil)
        type.name = "Poem Line"
        let poem = try #require(GeneratedDeckEditorContext(item: item, itemType: type, deckName: "Selected deck"))
        #expect(poem.kind == .poem && poem.deckID == deckID && poem.itemTypeID == type.id)
        #expect(poem.deckName == "Selected deck")
        type.name = "Prose Unit"
        let prose = try #require(GeneratedDeckEditorContext(item: item, itemType: type))
        #expect(prose.kind == .prose && prose.deckName == "Prose")
        var unassigned = item
        unassigned.deckID = nil
        #expect(GeneratedDeckEditorContext(item: unassigned, itemType: type) == nil)
    }
}
