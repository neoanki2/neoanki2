/// rand 0.10 `StdRng` compatibility used by the pinned optimizer. The pinned
/// implementation is ChaCha12 with `SeedableRng.seed_from_u64`, followed by
/// rand's `IncreasingUniform` slice shuffle.
struct RandCompatibleRandom: Sendable {
    private var key: [UInt32]
    private var counter: UInt64 = 0
    private var stream: UInt64 = 0
    private var buffer = [UInt32](repeating: 0, count: 16)
    private var bufferIndex = 16

    init(seed: UInt64) {
        var pcgState = seed
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for _ in 0..<8 {
            pcgState = pcgState &* 6_364_136_223_846_793_005 &+ 11_634_580_027_462_260_723
            let xorshifted = UInt32(truncatingIfNeeded: ((pcgState >> 18) ^ pcgState) >> 27)
            let rotation = UInt32(truncatingIfNeeded: pcgState >> 59)
            let word = xorshifted.rotateRight(rotation)
            bytes.append(UInt8(truncatingIfNeeded: word))
            bytes.append(UInt8(truncatingIfNeeded: word >> 8))
            bytes.append(UInt8(truncatingIfNeeded: word >> 16))
            bytes.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        key = Self.decodeKey(bytes)
    }

    init(seedBytes: [UInt8]) {
        precondition(seedBytes.count == 32)
        key = Self.decodeKey(seedBytes)
    }

    mutating func nextUInt32() -> UInt32 {
        if bufferIndex == 16 { refill() }
        defer { bufferIndex += 1 }
        return buffer[bufferIndex]
    }

    mutating func nextUInt64() -> UInt64 {
        UInt64(nextUInt32()) | UInt64(nextUInt32()) << 32
    }

    mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        var chooser = IncreasingUniform(start: 0)
        for index in values.indices {
            values.swapAt(index, chooser.next(using: &self))
        }
    }

    fileprivate mutating func randomRange(upperBound range: UInt32) -> UInt32 {
        precondition(range > 0)
        let product = UInt64(nextUInt32()) * UInt64(range)
        var result = UInt32(truncatingIfNeeded: product >> 32)
        let low = UInt32(truncatingIfNeeded: product)
        if low > 0 &- range {
            let nextProduct = UInt64(nextUInt32()) * UInt64(range)
            let nextHigh = UInt32(truncatingIfNeeded: nextProduct >> 32)
            let (_, overflow) = low.addingReportingOverflow(nextHigh)
            if overflow { result &+= 1 }
        }
        return result
    }

    private mutating func refill() {
        let constants: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]
        var state = constants + key + [
            UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32),
            UInt32(truncatingIfNeeded: stream), UInt32(truncatingIfNeeded: stream >> 32),
        ]
        let initial = state
        for _ in 0..<6 {
            Self.quarter(&state, 0, 4, 8, 12)
            Self.quarter(&state, 1, 5, 9, 13)
            Self.quarter(&state, 2, 6, 10, 14)
            Self.quarter(&state, 3, 7, 11, 15)
            Self.quarter(&state, 0, 5, 10, 15)
            Self.quarter(&state, 1, 6, 11, 12)
            Self.quarter(&state, 2, 7, 8, 13)
            Self.quarter(&state, 3, 4, 9, 14)
        }
        for index in state.indices { state[index] &+= initial[index] }
        buffer = state
        bufferIndex = 0
        counter &+= 1
    }

    private static func decodeKey(_ bytes: [UInt8]) -> [UInt32] {
        stride(from: 0, to: 32, by: 4).map { index in
            let byte0 = UInt32(bytes[index])
            let byte1 = UInt32(bytes[index + 1]) << 8
            let byte2 = UInt32(bytes[index + 2]) << 16
            let byte3 = UInt32(bytes[index + 3]) << 24
            return byte0 | byte1 | byte2 | byte3
        }
    }

    private static func quarter(
        _ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int
    ) {
        state[a] &+= state[b]; state[d] ^= state[a]; state[d] = state[d].rotateLeft(16)
        state[c] &+= state[d]; state[b] ^= state[c]; state[b] = state[b].rotateLeft(12)
        state[a] &+= state[b]; state[d] ^= state[a]; state[d] = state[d].rotateLeft(8)
        state[c] &+= state[d]; state[b] ^= state[c]; state[b] = state[b].rotateLeft(7)
    }
}

private struct IncreasingUniform {
    var n: UInt32
    var chunk: UInt32 = 0
    var remaining: UInt8

    init(start: UInt32) {
        n = start
        remaining = start == 0 ? 1 : 0
    }

    mutating func next(using random: inout RandCompatibleRandom) -> Int {
        let nextN = n + 1
        let nextRemaining: UInt8
        if let decremented = remaining.subtractingReportingOverflow(1).overflow ? nil : remaining - 1 {
            nextRemaining = decremented
        } else {
            let calculated = Self.bound(startingAt: nextN)
            chunk = random.randomRange(upperBound: calculated.0)
            nextRemaining = calculated.1 - 1
        }
        let result: UInt32
        if nextRemaining == 0 {
            result = chunk
        } else {
            result = chunk % nextN
            chunk /= nextN
        }
        remaining = nextRemaining
        n = nextN
        return Int(result)
    }

    private static func bound(startingAt start: UInt32) -> (UInt32, UInt8) {
        var product = start
        var current = start + 1
        while true {
            let multiplied = product.multipliedReportingOverflow(by: current)
            if multiplied.overflow { return (product, UInt8(current - start)) }
            product = multiplied.partialValue
            current += 1
        }
    }
}

private extension UInt32 {
    func rotateLeft(_ count: UInt32) -> UInt32 { self << count | self >> (32 - count) }
    func rotateRight(_ count: UInt32) -> UInt32 { self >> count | self << (32 - count) }
}
