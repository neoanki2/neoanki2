import CryptoKit
import Foundation

struct OptimizerReferenceFixture: Decodable {
    struct Configuration: Decodable {
        let epochs: Int
        let batchSize: Int
        let seed: UInt64
        let learningRate: Double
        let maximumSequenceLength: Int
        let regularizationGamma: Double
    }

    struct GradientCase: Decodable {
        let times: [Float]
        let ratings: [Float]
        let delta: Float
        let label: Float
        let loss: Double
        let gradient: [Double]
    }

    struct BatchStructure: Decodable {
        struct WeightRow: Decodable {
            let row: Int
            let nonzeroCount: Int
            let first: Float
            let last: Float
        }

        let sequenceLength: Int
        let batchSize: Int
        let realBatchSize: Int
        let columnLength: Int
        let timeRows: [Float]
        let firstRatingCycle: [Float]
        let secondRatingAgainStride: Int
        let thirdRatingHardStride: Int
        let labelRowSuccessCounts: [Int]
        let weightRows: [WeightRow]
    }

    struct Evaluation: Decodable {
        let logLoss: Double
        let rmseBins: Double
    }

    let upstreamCommit: String
    let rustc: String
    let cargo: String
    let randResolvedVersion: String
    let trainingConfiguration: Configuration
    let permutations: [[Int]]
    let gradientCases: [GradientCase]
    let batchStructure: BatchStructure
    let cosineRates: [Double]
    let adamSteps: [[Float]]
    let finalParameters: [Float]
    let evaluation: Evaluation

    static func load() throws -> Self {
        try FixtureFiles.decode(Self.self, named: "optimizer-reference")
    }
}

struct VerificationManifest: Decodable {
    let upstreamCommit: String
    let githubCommitTarballSha256: String
    let gitArchiveTarSha256: String
    let fixtures: [String: String]
    let verificationReportSha256: String
    let status: String

    static func load() throws -> Self {
        try FixtureFiles.decode(Self.self, named: "verification-manifest")
    }
}

enum FixtureFiles {
    static func decode<Value: Decodable>(_ type: Value.Type, named name: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data(named: name))
    }

    static func data(named name: String, extension fileExtension: String = "json") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func sha256(named name: String, extension fileExtension: String = "json") throws -> String {
        SHA256.hash(data: try data(named: name, extension: fileExtension))
            .map { String(format: "%02x", $0) }.joined()
    }
}
