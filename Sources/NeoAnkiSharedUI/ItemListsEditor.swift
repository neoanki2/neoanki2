import NeoAnkiCore
import SwiftUI

public struct ItemListsEditor: View {
    @Binding private var lists: [ItemList]

    public init(lists: Binding<[ItemList]>) { _lists = lists }

    public var body: some View {
        ForEach($lists) { $list in
            DisclosureGroup(list.name.isEmpty ? "Untitled list" : list.name) {
                TextField("List name", text: $list.name)
                Toggle("Share rows across items", isOn: Binding(
                    get: { list.sharedRows != nil },
                    set: { shared in list.sharedRows = shared ? [] : nil }
                ))
                ForEach($list.columns) { $column in
                    VStack(alignment: .leading) {
                        TextField("Column name", text: $column.name)
                        Picker("Column type", selection: $column.type) {
                            Text("Text").tag(FieldType.text)
                            Text("Rich Text").tag(FieldType.richText)
                            Text("Number").tag(FieldType.number)
                            Text("Checkbox").tag(FieldType.checkbox)
                            Text("Cloze").tag(FieldType.cloze)
                        }
                        Toggle("Required", isOn: $column.isRequired)
                        Button("Remove Column", role: .destructive) {
                            let id = column.id
                            list.columns.removeAll { $0.id == id }
                            for index in list.sharedRows?.indices ?? 0..<0 {
                                list.sharedRows?[index].values.removeAll { $0.fieldID == id }
                            }
                        }
                    }
                }
                Button("Add Column", systemImage: "plus") {
                    list.columns.append(FieldDef(name: "", type: .text))
                }
                if list.sharedRows != nil {
                    ItemListRowsEditor(list: list, rows: Binding(
                        get: { list.sharedRows ?? [] },
                        set: { list.sharedRows = $0 }
                    ))
                }
                Button("Remove List", role: .destructive) {
                    let id = list.id
                    lists.removeAll { $0.id == id }
                }
            }
        }
        Button("Add List", systemImage: "plus") {
            lists.append(ItemList(name: "", columns: [FieldDef(name: "", type: .text)]))
        }
    }
}

public struct ItemListRowsEditor: View {
    let list: ItemList
    @Binding var rows: [ItemListRow]

    public init(list: ItemList, rows: Binding<[ItemListRow]>) {
        self.list = list
        _rows = rows
    }

    public var body: some View {
        ForEach($rows) { $row in
            let title = row.values.lazy.map(\.value.plainText).first { !$0.isEmpty }
            DisclosureGroup(title ?? "Row \((rows.firstIndex { $0.id == row.id } ?? 0) + 1)") {
                ForEach(list.columns) { column in
                    ListCellEditor(column: column, value: Binding(
                        get: { row.values.first { $0.fieldID == column.id }?.value ?? .empty },
                        set: { value in
                            row.values.removeAll { $0.fieldID == column.id }
                            if !value.isEmpty { row.values.append(FieldValue(fieldID: column.id, value: value)) }
                        }
                    ))
                }
                Button("Remove Row", role: .destructive) {
                    let id = row.id
                    rows.removeAll { $0.id == id }
                }
            }
        }
        Button("Add Row", systemImage: "plus") { rows.append(ItemListRow()) }
    }
}

private struct ListCellEditor: View {
    let column: FieldDef
    @Binding var value: ContentValue
    @State private var blankText = ""

    var body: some View {
        switch column.type {
        case .checkbox:
            Toggle(column.name, isOn: Binding(
                get: { value == .checkbox(true) },
                set: { value = .checkbox($0) }
            ))
        case .number:
            TextField(column.name, value: Binding<Double?>(
                get: { if case let .number(number) = value { number } else { nil } },
                set: { value = $0.map(ContentValue.number) ?? .empty }
            ), format: .number)
        case .cloze:
            TextField(column.name, text: Binding(get: { value.plainText }, set: { text in
                let blanks = ClozeSpanRebaser.rebase(spans: clozeBlanks, from: value.plainText, to: text).spans
                value = .cloze(text, blanks: blanks)
            }), axis: .vertical)
            HStack {
                TextField("Text to hide", text: $blankText)
                Button("Add Blank") { addBlank() }
                    .buttonStyle(.borderless)
                    .disabled(blankRange == nil)
            }
            if !clozeBlanks.isEmpty {
                Text(ClozeValidation.displayText(from: value.plainText, blanks: clozeBlanks, revealed: false))
                    .foregroundStyle(.secondary)
                Button("Clear Blanks") { value = .cloze(value.plainText, blanks: []) }
                    .buttonStyle(.borderless)
            }
        case .text, .richText:
            TextField(column.name, text: Binding(
                get: { value.plainText },
                set: { value = column.type == .richText ? .rich([Span($0)]) : .text($0) }
            ), axis: .vertical)
        default: EmptyView()
        }
    }

    private var clozeBlanks: [ClozeSpan] {
        guard case let .cloze(_, blanks) = value else { return [] }
        return blanks
    }

    private var blankRange: Range<String.Index>? {
        guard !blankText.isEmpty else { return nil }
        let text = value.plainText
        var start = text.startIndex
        while start < text.endIndex, let match = text.range(of: blankText, range: start..<text.endIndex) {
            let offset = text.distance(from: text.startIndex, to: match.lowerBound)
            let end = offset + text.distance(from: match.lowerBound, to: match.upperBound)
            if !clozeBlanks.contains(where: { offset < $0.start + $0.length && $0.start < end }) { return match }
            start = match.upperBound
        }
        return nil
    }

    private func addBlank() {
        guard let range = blankRange else { return }
        let text = value.plainText
        let group = (clozeBlanks.map(\.group).max() ?? 0) + 1
        value = .cloze(text, blanks: clozeBlanks + [ClozeSpan(
            group: group, start: text.distance(from: text.startIndex, to: range.lowerBound),
            length: text.distance(from: range.lowerBound, to: range.upperBound)
        )])
        blankText = ""
    }
}

private extension ContentValue {
    var plainText: String {
        if case let .cloze(text, _) = self { return text }
        return ItemDisplay.plainText(from: self)
    }
}

public enum CardCreationSummary {
    public static func message(for preview: CardCreationPreview) -> String {
        let counts = "Keep \(preview.kept), add \(preview.added), and retire \(preview.retired) cards."
        return preview.addedSuspended == 0 ? counts : counts + " \(preview.addedSuspended) new cards start suspended."
    }

    public static func preview(_ item: Item, type: ItemType, original: Item? = nil) -> CardCreationPreview {
        CardCreationPreview(
            existing: original.map { CardGenerator.cards(for: $0, type: type) } ?? [],
            desired: CardGenerator.cards(for: item, type: type)
        )
    }
}

/// Interactive preview of a generated card using the same resolved content and
/// answer evaluator as a regular session.
public struct ItemGeneratedCardPreview: View {
    private let cards: [Card]
    private let item: Item
    private let type: ItemType
    private let mediaStore: MediaStore?
    @State private var index = 0
    @State private var revealed = false
    @State private var typedAnswer = ""
    @State private var evaluation: AnswerEvaluation?

    public init(item: Item, type: ItemType, mediaStore: MediaStore? = nil) {
        self.item = item
        self.type = type
        self.mediaStore = mediaStore
        cards = CardGenerator.cards(for: item, type: type, deterministicIDs: true)
    }

    public var body: some View {
        if let card = cards.isEmpty ? nil : cards[min(index, cards.count - 1)],
           let template = type.templates.first(where: { $0.id == card.templateID }) {
            let due = DueCard(card: card, item: item, itemType: type, template: template)
            DisclosureGroup("Preview a card") {
                LabeledContent(template.name, value: "\(min(index + 1, cards.count)) of \(cards.count)")
                ForEach(due.studyComponents) { component in
                    if component.purpose != .expectedAnswer || revealed,
                       component.presentation.reveal == .always || revealed {
                        preview(component.value, card: card)
                    }
                }
                if !revealed {
                    if due.response == .type {
                        TextField("Type an answer", text: $typedAnswer)
                        Button("Check Answer") {
                            evaluation = StudyResponseEvaluator.evaluate(typedAnswer, for: due)
                            revealed = true
                        }
                        .disabled(typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button("Show Answer") { revealed = true }
                }
                if let evaluation {
                    switch evaluation {
                    case .correct: Label("Correct", systemImage: "checkmark.circle")
                    case .incorrect: Label("Try again", systemImage: "xmark.circle")
                    case .unavailable: Text("No checkable answer")
                    }
                }
                if cards.count > 1 {
                    Button("Next Card") { index = (index + 1) % cards.count; resetAnswer() }
                }
            }
            .onChange(of: item.fields) { resetAnswer() }
        }
    }

    private func resetAnswer() {
        revealed = false
        typedAnswer = ""
        evaluation = nil
    }

    @ViewBuilder
    private func preview(_ value: ContentValue, card: Card) -> some View {
        switch value {
        case let .cloze(text, blanks):
            Text(SharedStudyClozePresentation.displayText(
                from: text, blanks: blanks, isAnswerRevealed: revealed, group: card.clozeGroup
            ))
        case let .imageOcclusion(content):
            ImageOcclusionStudyView(content: content, mediaStore: mediaStore, group: card.occlusionGroup, revealed: revealed)
        default:
            Text(ItemDisplay.plainText(from: value))
        }
    }
}
