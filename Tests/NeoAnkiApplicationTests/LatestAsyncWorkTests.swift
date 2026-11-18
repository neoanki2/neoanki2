import NeoAnkiApplication
import Testing

private actor LatestWorkGate {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var values: [Int] = []
    private(set) var active = 0
    private(set) var maximumActive = 0

    func perform(_ value: Int) async {
        active += 1
        maximumActive = max(maximumActive, active)
        if value == 0 {
            entered = true
            observer?.resume(); observer = nil
            await withCheckedContinuation { continuation = $0 }
        }
        values.append(value)
        active -= 1
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite @MainActor struct LatestAsyncWorkTests {
    @Test func stalledWorkHasOneReplaceablePendingRequestAndNeverOverlapsWrites() async {
        let gate = LatestWorkGate()
        let work = LatestAsyncWork<Int> { await gate.perform($0) }
        work.request(0)
        await gate.waitUntilEntered()
        for value in 1...100 { work.request(value) }
        #expect(work.isRunning)
        #expect(work.pendingRequestCount == 1)
        #expect(await gate.values.isEmpty)
        await gate.release()
        await work.waitUntilSettled()
        #expect(await gate.values == [0, 100])
        #expect(await gate.maximumActive == 1)
        #expect(!work.isRunning && work.pendingRequestCount == 0)
    }

    @Test func cancellationDoesNotPretendAnUncooperativeEffectStopped() async {
        let gate = LatestWorkGate()
        let work = LatestAsyncWork<Int> { await gate.perform($0) }
        work.request(0)
        await gate.waitUntilEntered()
        work.request(1)
        work.cancel()
        work.request(2)
        #expect(work.isRunning)
        #expect(work.pendingRequestCount == 0)
        await gate.release()
        await work.waitUntilSettled()
        #expect(await gate.values == [0])
        #expect(await gate.maximumActive == 1)
        #expect(!work.isRunning)
    }
}
