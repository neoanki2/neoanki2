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

    private var preparedView: ((DeckBuilderHostContext,
        @escaping @MainActor (GeneratedDeckCreation) -> Void,
        @escaping @MainActor () -> Void) -> AnyView)?

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

    /// Additive native path; existing features and bundle callbacks remain valid.
    public func withPreparedView<Content: View>(@ViewBuilder _ factory: @escaping (
        DeckBuilderHostContext, @escaping @MainActor (GeneratedDeckCreation) -> Void,
        @escaping @MainActor () -> Void) -> Content) -> Self {
        var copy = self
        copy.preparedView = { context, created, cancel in AnyView(factory(context, created, cancel)) }
        return copy
    }

    public func makeCreationView(context: DeckBuilderHostContext,
        onPrepared: @escaping @MainActor (GeneratedDeckCreation) -> Void,
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void) -> AnyView {
        if let preparedView { return preparedView(context, onPrepared, onCancel) }
        return makeView(context: context, onGenerated: onGenerated, onCancel: onCancel)
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
