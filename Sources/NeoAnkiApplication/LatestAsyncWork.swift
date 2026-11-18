/// Runs optional asynchronous effects serially, retaining only the latest
/// request while work is active. A stalled effect never creates an unbounded
/// chain of tasks, and replacing pending work never overlaps active OS writes.
@MainActor
public final class LatestAsyncWork<Request: Sendable> {
    private let operation: @MainActor @Sendable (Request) async -> Void
    private var task: Task<Void, Never>?
    private var pending: Request?
    private var revision: UInt64 = 0
    private var cancelled = false

    public init(operation: @escaping @MainActor @Sendable (Request) async -> Void) {
        self.operation = operation
    }

    public var isRunning: Bool { task != nil }
    public var pendingRequestCount: Int { pending == nil ? 0 : 1 }

    /// Scheduling is synchronous. Callers may acknowledge a durable command
    /// immediately instead of awaiting an unrelated effect's completion.
    @discardableResult
    public func request(_ request: Request) -> UInt64 {
        guard !cancelled else { return revision }
        revision &+= 1
        pending = request
        guard task == nil else { return revision }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            while !Task.isCancelled, let request = pending {
                pending = nil
                await operation(request)
            }
        }
        return revision
    }

    /// Explicit observation/verification barrier; not part of command success.
    /// Waiting never cancels an OS operation that may still finish its write.
    public func waitUntilSettled() async {
        while let task { await task.value }
    }

    /// Terminal shutdown. The current operation is asked to cancel, but the
    /// worker retains its task until it really returns and admits no successor.
    public func cancel() {
        cancelled = true
        pending = nil
        task?.cancel()
    }
}
