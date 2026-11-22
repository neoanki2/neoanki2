import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

/// A scrollable lesson shares the study shell and keeps its progression action
/// visible. Native media and rich-text rendering are supplied by each platform.
public struct StudyLessonReader<Block: View>: View {
    private let load: () async throws -> StudyLessonContent
    private let canContinue: Bool
    private let saveError: String?
    private let onContinue: () -> Void
    private let block: (ContentValue) -> Block
    @State private var content: StudyLessonContent?
    @State private var loadError: String?
    @State private var loadAttempt = 0

    public init(load: @escaping () async throws -> StudyLessonContent, canContinue: Bool,
                saveError: String? = nil, onContinue: @escaping () -> Void,
                @ViewBuilder block: @escaping (ContentValue) -> Block) {
        self.load = load
        self.canContinue = canContinue
        self.saveError = saveError
        self.onContinue = onContinue
        self.block = block
    }

    public var body: some View {
        AdaptiveStudyStage(layout: .focus) {
            if let content {
                ScrollView {
                    AdaptiveReadingColumn {
                        LazyVStack(alignment: .leading, spacing: SharedDesignSystem.sectionSpacing) {
                            Text(content.title)
                                .font(.title.bold())
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("studyLessonTitle")
                            ForEach(content.blocks.indices, id: \.self) { index in
                                block(content.blocks[index])
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .padding(.vertical, SharedDesignSystem.sectionSpacing)
                    }
                }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Lesson", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { loadAttempt += 1 }
                }
            } else {
                ProgressView("Loading lesson…")
            }
        } footer: {
            VStack(spacing: SharedDesignSystem.compactSpacing) {
                if let saveError { Text(saveError).font(.callout).foregroundStyle(.secondary) }
                Button(action: onContinue) {
                    Text("Continue")
                        .frame(maxWidth: .infinity, minHeight: SharedDesignSystem.minimumTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .neoAnkiMobilePrimaryActionTint()
                .keyboardShortcut(.defaultAction)
                .disabled(content == nil || !canContinue)
                .accessibilityIdentifier("continueStudyLesson")
            }
            .padding(SharedDesignSystem.standardSpacing)
        }
        .task(id: loadAttempt) {
            loadError = nil
            do { content = try await load() }
            catch is CancellationError { }
            catch { loadError = error.localizedDescription }
        }
    }
}
