import Foundation

/// A card ready for study, with the item and template needed to render it.
public struct DueCard: Sendable, Identifiable, Equatable {
    public var id: UUID { card.id }
    public var card: Card
    public var item: Item
    public var itemType: ItemType
    public var template: Template
    public var studyRelation: StudyCardRelation?

    public var studyItem: Item {
        CardGenerator.boundItem(item, type: itemType, selections: card.rowSelections) ?? item
    }

    public var response: ResponseMode {
        if item.itemTypeID == VocabularySet.legacyTypeID, VocabularySet.supportsTypedResponse(self), template.responseOverride == nil { return .type }
        return template.response
    }

    public var studyComponents: [ResolvedTemplateComponent] {
        VocabularySet.studyComponents(for: template, from: studyItem, clozeGroup: card.clozeGroup)
    }

    public init(card: Card, item: Item, itemType: ItemType, template: Template, studyRelation: StudyCardRelation? = nil) {
        self.card = card
        self.item = item
        self.itemType = itemType
        self.template = template
        self.studyRelation = studyRelation
    }
}
