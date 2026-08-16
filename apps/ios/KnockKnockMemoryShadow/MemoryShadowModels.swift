import Foundation

/// The complete capability surface available to the read-only E5 shadow.
///
/// Implementations may only accept `display_text` fixtures and emit a private
/// report. There is no mutation, networking, command-envelope, execution,
/// ranking, or UI capability in this protocol for an implementation to call.
public protocol MemoryShadowQualificationReporting: Sendable {
    func makeReport(
        fixture: MemoryShadowFixture
    ) async throws -> MemoryShadowQualificationReport
}

public struct MemoryShadowFixture: Sendable {
    public let memories: [MemoryShadowMemoryFixture]
    public let queries: [MemoryShadowQueryFixture]

    public init(
        memories: [MemoryShadowMemoryFixture],
        queries: [MemoryShadowQueryFixture]
    ) {
        self.memories = memories
        self.queries = queries
    }
}

public struct MemoryShadowMemoryFixture: Hashable, Sendable {
    public let memoryID: String
    /// The only memory field exposed to the shadow runtime.
    public let displayText: String

    public init(memoryID: String, displayText: String) {
        self.memoryID = memoryID
        self.displayText = displayText
    }
}

public struct MemoryShadowQueryFixture: Hashable, Sendable {
    public let queryID: String
    public let locale: String
    public let expectedMemoryID: String
    public let displayText: String

    public init(
        queryID: String,
        locale: String,
        expectedMemoryID: String,
        displayText: String
    ) {
        self.queryID = queryID
        self.locale = locale
        self.expectedMemoryID = expectedMemoryID
        self.displayText = displayText
    }
}

public struct MemoryShadowLocaleMetrics: Codable, Equatable, Sendable {
    public let correct: Int
    public let total: Int

    public init(correct: Int, total: Int) {
        self.correct = correct
        self.total = total
    }

    public var accuracy: Double {
        guard total > 0 else { return 0 }
        return Double(correct) / Double(total)
    }
}

public struct MemoryShadowPrediction: Codable, Equatable, Sendable {
    public let queryID: String
    public let locale: String
    public let expectedMemoryID: String
    public let predictedMemoryID: String
    public let correct: Bool
    public let topCosineSimilarity: Float
    public let topOneMargin: Float

    public init(
        queryID: String,
        locale: String,
        expectedMemoryID: String,
        predictedMemoryID: String,
        correct: Bool,
        topCosineSimilarity: Float,
        topOneMargin: Float
    ) {
        self.queryID = queryID
        self.locale = locale
        self.expectedMemoryID = expectedMemoryID
        self.predictedMemoryID = predictedMemoryID
        self.correct = correct
        self.topCosineSimilarity = topCosineSimilarity
        self.topOneMargin = topOneMargin
    }
}

/// Report-only output. Nothing in this type can be fed into app state or a
/// command transport without a new, explicit production integration.
public struct MemoryShadowQualificationReport: Codable, Equatable, Sendable {
    public let queryCount: Int
    public let correctCount: Int
    public let recallAtOne: Double
    public let p50Seconds: Double
    public let p95Seconds: Double
    public let minimumTopOneMargin: Float
    public let localeMetrics: [String: MemoryShadowLocaleMetrics]
    public let predictions: [MemoryShadowPrediction]

    public init(
        queryCount: Int,
        correctCount: Int,
        recallAtOne: Double,
        p50Seconds: Double,
        p95Seconds: Double,
        minimumTopOneMargin: Float,
        localeMetrics: [String: MemoryShadowLocaleMetrics],
        predictions: [MemoryShadowPrediction]
    ) {
        self.queryCount = queryCount
        self.correctCount = correctCount
        self.recallAtOne = recallAtOne
        self.p50Seconds = p50Seconds
        self.p95Seconds = p95Seconds
        self.minimumTopOneMargin = minimumTopOneMargin
        self.localeMetrics = localeMetrics
        self.predictions = predictions
    }
}

public enum MemoryShadowQualificationError: Error, Equatable, Sendable {
    case emptyMemories
    case emptyQueries
    case duplicateMemoryID(String)
    case missingEmbedding(expected: Int, actual: Int)
    case invalidEmbeddingDimensions
    case zeroMagnitudeEmbedding
}
