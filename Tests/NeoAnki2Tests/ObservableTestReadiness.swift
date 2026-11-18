import Observation

/// Waits for observable state, independent of executor load or wall-clock
/// latency. AsyncStream buffers changes during registration and terminates its
/// suspended iterator on task cancellation, so cancelled tests can unwind.
@MainActor
func waitForObservedCondition(_ condition: @escaping @MainActor () -> Bool) async throws {
    while true {
        try Task.checkCancellation()
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        let ready = withObservationTracking {
            condition()
        } onChange: {
            continuation.yield(())
            continuation.finish()
        }
        if ready { return }
        var iterator = changes.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }
}
