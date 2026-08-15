/// Immutable identity of the upstream implementation this Swift port follows.
public enum FSRSReference: Sendable {
    public static let modelIdentifier = "fsrs-rs-main-6f5498f8-fsrs6-swift-v1"
    public static let upstreamCommit = "6f5498f8dd1a95c781fcdd4448f28f16dd9e377d"
    public static let upstreamVersion = "6.6.2"
    /// SHA-256 of `git archive --format=tar 6f5498f8...` from a checkout.
    public static let gitArchiveSHA256 = "22664035118f2179a89fbc255a0323e862d6e36b9cefd64ac9bcf9f75acf75c7"
    /// SHA-256 of GitHub's commit tarball response for the pinned commit.
    public static let githubTarballSHA256 = "356b1bac9eab9cd51fad729b844d84c6a7601560b219868f26888457975ade1d"
    public static let sourceArchiveSHA256 = githubTarballSHA256
    public static let license = "BSD-3-Clause"
    /// The committed Swift-only parity suite covers gradients, RNG/shuffle,
    /// batching, optimizer primitives, complete training, and evaluation.
    public static let optimizerParityVerified = true
}
