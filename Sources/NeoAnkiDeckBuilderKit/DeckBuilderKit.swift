@_exported import NeoAnkiDeckBuilderCore
import SwiftUI

@MainActor
public struct AnyDeckBuilderFeature: Identifiable {
    public let descriptor: DeckBuilderDescriptor
    private let makeViewOperation: (
        DeckBuilderHostContext,
        @escaping @MainActor (GeneratedDeckBundle) -> Void,
        @escaping @MainActor () -> Void
    ) -> AnyView

    public nonisolated var id: String { descriptor.id }

    public init<Content: View>(
        descriptor: DeckBuilderDescriptor,
        @ViewBuilder makeView: @escaping (
            DeckBuilderHostContext,
            @escaping @MainActor (GeneratedDeckBundle) -> Void,
            @escaping @MainActor () -> Void
        ) -> Content
    ) {
        self.descriptor = descriptor
        makeViewOperation = { context, onGenerated, onCancel in
            AnyView(makeView(context, onGenerated, onCancel))
        }
    }

    public func makeView(
        context: DeckBuilderHostContext,
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) -> AnyView {
        makeViewOperation(context, onGenerated, onCancel)
    }
}

@MainActor
public struct DeckBuilderRegistry {
    public let features: [AnyDeckBuilderFeature]

    public init(_ features: [AnyDeckBuilderFeature]) {
        self.features = features
    }

    public func feature(id: String) -> AnyDeckBuilderFeature? {
        features.first { $0.id == id }
    }
}
