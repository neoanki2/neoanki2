import SwiftUI

/// A single dismissal path for Cancel, Escape, and host navigation.
@MainActor @Observable
public final class DraftDismissal {
    public let id = UUID()
    public var confirmsDiscard = false
    @ObservationIgnored private var pendingAction: (() -> Void)?
    public init() {}

    public func request(isDirty: Bool, isBusy: Bool = false, action: @escaping () -> Void) {
        guard !isBusy else { return }
        if isDirty {
            pendingAction = action
            confirmsDiscard = true
        } else { action() }
    }
    public func discard() {
        let action = pendingAction
        pendingAction = nil
        confirmsDiscard = false
        action?()
    }
    public func keepEditing() { pendingAction = nil; confirmsDiscard = false }
}

public struct DraftNavigationGuard {
    public let id: UUID
    public let isDirty: Bool
    public let isBusy: Bool
    public var request: (@escaping () -> Void) -> Void
    public init(id: UUID, isDirty: Bool, isBusy: Bool, request: @escaping (@escaping () -> Void) -> Void) {
        self.id = id; self.isDirty = isDirty; self.isBusy = isBusy; self.request = request
    }
}

private struct DraftNavigationGuardKey: PreferenceKey {
    static var defaultValue: DraftNavigationGuard? { nil }
    static func reduce(value: inout DraftNavigationGuard?, nextValue: () -> DraftNavigationGuard?) {
        value = nextValue() ?? value
    }
}

extension View {
    public func protectDraft(isDirty: Bool, isBusy: Bool = false, dismissal: DraftDismissal) -> some View {
        modifier(DraftProtectionModifier(isDirty: isDirty, isBusy: isBusy, dismissal: dismissal))
    }
    public func onDraftNavigationGuardChange(_ action: @escaping (DraftNavigationGuard?) -> Void) -> some View {
        onPreferenceChange(DraftNavigationGuardKey.self, perform: action)
    }
}

// Preference updates compare identity, not closures. The host always receives
// the latest draft state through the guard installed by the modifier.
extension DraftNavigationGuard: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.isDirty == rhs.isDirty && lhs.isBusy == rhs.isBusy
    }
}

private struct DraftProtectionModifier: ViewModifier {
    let isDirty: Bool
    let isBusy: Bool
    @Bindable var dismissal: DraftDismissal
    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty || isBusy)
            .preference(key: DraftNavigationGuardKey.self, value: DraftNavigationGuard(id: dismissal.id, isDirty: isDirty, isBusy: isBusy) { action in
                dismissal.request(isDirty: isDirty, isBusy: isBusy, action: action)
            })
            .confirmationDialog("Discard changes?", isPresented: $dismissal.confirmsDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismissal.discard() }
                Button("Keep Editing", role: .cancel) { dismissal.keepEditing() }
            } message: { Text("Your unsaved changes will be lost.") }
    }
}
