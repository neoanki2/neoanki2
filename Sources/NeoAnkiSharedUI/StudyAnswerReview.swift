import Foundation
import NeoAnkiCore
import SwiftUI

/// Keep answer-only notes out of the comparison without changing authored data.
public struct StudyAnswerReviewProjection {
    public let prompt: [ResolvedTemplateComponent]
    public let answer: [ResolvedTemplateComponent]
    public let explanation: [ResolvedTemplateComponent]

    public init(components: [ResolvedTemplateComponent]) {
        answer = components.filter { $0.purpose == .expectedAnswer }
        explanation = components.filter(Self.isExplanation)
        prompt = components.filter { $0.purpose != .expectedAnswer && !Self.isExplanation($0) }
    }

    private static func isExplanation(_ component: ResolvedTemplateComponent) -> Bool {
        component.purpose == .supporting && component.presentation.reveal == .hiddenUntilAnswer
    }
}

public struct StudyAnswerDifference {
    public struct Segment: Equatable {
        public let text: String
        public let changed: Bool
    }

    public let response: [Segment]
    public let answer: [Segment]

    public init(response: String, answer: String) {
        let responseTokens = Self.tokens(response)
        let answerTokens = Self.tokens(answer)
        let difference = answerTokens.filter { !$0.allSatisfy(\.isWhitespace) }
            .difference(from: responseTokens.filter { !$0.allSatisfy(\.isWhitespace) })
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        self.response = Self.segments(responseTokens, changed: removed)
        self.answer = Self.segments(answerTokens, changed: inserted)
    }

    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var wasWhitespace: Bool?
        for character in text {
            if let wasWhitespace, wasWhitespace != character.isWhitespace {
                tokens.append(token)
                token = ""
            }
            token.append(character)
            wasWhitespace = character.isWhitespace
        }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private static func segments(_ tokens: [String], changed: Set<Int>) -> [Segment] {
        var wordIndex = 0
        return tokens.map { token in
            guard !token.allSatisfy(\.isWhitespace) else { return Segment(text: token, changed: false) }
            defer { wordIndex += 1 }
            return Segment(text: token, changed: changed.contains(wordIndex))
        }
    }
}

/// Native review content shared by the mobile reader and Mac study stage.
public struct StudyAnswerReview<Content: View>: View {
    let layout: CardLayoutID
    let components: [ResolvedTemplateComponent]
    let isAnswerRevealed: Bool
    let response: String?
    let evaluation: AnswerEvaluation?
    let mobileReading: Bool
    let enabled: Bool
    let content: (ResolvedTemplateComponent, CardWireframeHole) -> Content
    @State private var showsExplanation = false

    public init(
        layout: CardLayoutID,
        components: [ResolvedTemplateComponent],
        isAnswerRevealed: Bool,
        response: String? = nil,
        evaluation: AnswerEvaluation? = nil,
        mobileReading: Bool = false,
        enabled: Bool = true,
        @ViewBuilder content: @escaping (ResolvedTemplateComponent, CardWireframeHole) -> Content
    ) {
        self.layout = layout
        self.components = components
        self.isAnswerRevealed = isAnswerRevealed
        self.response = response
        self.evaluation = evaluation
        self.mobileReading = mobileReading
        self.enabled = enabled
        self.content = content
    }

    public var body: some View {
        if enabled {
            review
        } else {
            CardWireframeView(
                layout: layout, components: components,
                isAnswerRevealed: isAnswerRevealed, mobileReading: mobileReading,
                componentView: content
            )
        }
    }

    private var review: some View {
        let projection = StudyAnswerReviewProjection(components: components)
        return VStack(alignment: .leading, spacing: 16) {
            CardWireframeView(
                layout: layout,
                components: isAnswerRevealed ? projection.prompt : components,
                isAnswerRevealed: isAnswerRevealed,
                mobileReading: mobileReading
            ) { component, hole in
                VStack(alignment: .leading, spacing: 4) {
                    if component.id == projection.prompt.first(where: {
                        $0.region == .supporting && $0.purpose == .supporting
                    })?.id {
                        caption("Context")
                    }
                    content(component, hole)
                }
            }

            if isAnswerRevealed {
                let difference = textDifference(in: projection.answer)
                if let response {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            caption("Your answer")
                            Spacer()
                            if let evaluation, evaluation != .unavailable {
                                Text(evaluation == .correct ? "Matches" : "Differs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier(evaluation == .correct ? "answerCorrect" : "answerIncorrect")
                            }
                        }
                        Text(difference.map { attributed($0.response) } ?? AttributedString(response))
                            .font(.body)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("studySubmittedAnswer")
                }

                if !projection.answer.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        caption("Answer")
                        if let difference {
                            Text(attributed(difference.answer))
                                .font(.body)
                        } else {
                            ForEach(projection.answer) { component in
                                content(component, .answer)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("studyExpectedAnswer")
                }

                if !projection.explanation.isEmpty {
                    DisclosureGroup(isExpanded: $showsExplanation) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(projection.explanation) { component in
                                content(component, .context)
                            }
                        }
                        .font(.body)
                        .padding(.top, 8)
                    } label: {
                        Text("Explanation")
                            .frame(minHeight: SharedDesignSystem.minimumTouchTarget)
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("studyExplanation")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isAnswerRevealed) { _, _ in showsExplanation = false }
    }

    private func caption(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
    }

    private func textDifference(in answer: [ResolvedTemplateComponent]) -> StudyAnswerDifference? {
        guard let response, evaluation == .incorrect, answer.count == 1,
              case let .text(text, _) = answer[0].value else { return nil }
        return StudyAnswerDifference(response: response, answer: text)
    }

    private func attributed(_ segments: [StudyAnswerDifference.Segment]) -> AttributedString {
        segments.reduce(into: AttributedString()) { result, segment in
            var text = AttributedString(segment.text)
            if segment.changed {
                text.inlinePresentationIntent = .stronglyEmphasized
                text.underlineStyle = .single
            }
            result.append(text)
        }
    }
}
