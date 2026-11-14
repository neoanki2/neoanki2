import CryptoKit
import Foundation

/// Operational scheduling variation is deliberately outside the FSRS engine.
/// Its stable quantile makes previews reproducible and keeps rating order intact.
public enum ReviewIntervalVariation {
    public static let policyIdentifier = "continuous-varied-due-v1"
    public static let fraction = 0.15

    public static func apply(
        to memory: MemoryState, cardID: UUID, now: Date, maximumIntervalDays: Int
    ) -> MemoryState {
        guard memory.phase == .review else { return memory }
        let maximum = Double(maximumIntervalDays) * 86_400
        let interval = min(maximum, max(1, memory.due.timeIntervalSince(now)))
        let lower = max(1, ceil(interval * (1 - fraction)))
        let upper = max(lower, min(maximum, floor(interval * (1 + fraction))))
        let signature = "\(policyIdentifier)|\(cardID.uuidString.lowercased())|\(memory.reps)"
        let bytes = SHA256.hash(data: Data(signature.utf8))
        // 53 bits are exactly representable in Double, independent of architecture.
        let bits = bytes.prefix(7).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } >> 3
        let unit = Double(bits) / Double(UInt64(1) << 53)
        var result = memory
        result.due = now.addingTimeInterval(lower + floor(unit * (upper - lower + 1)))
        return result
    }
}
