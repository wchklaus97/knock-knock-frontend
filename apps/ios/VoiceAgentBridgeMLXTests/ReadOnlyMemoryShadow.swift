import Foundation
import MLX
import MLXEmbedders

/// The complete capability surface available to the qualification shadow.
///
/// This protocol intentionally lives in the iOS 17 MLX test target. It accepts
/// synthetic fixtures and can only emit a test report. There is no mutation,
/// networking, command-envelope, execution, ordering, or UI capability in the
/// protocol for an implementation to call.
protocol MemoryShadowQualificationReporting {
    func makeReport(
        fixture: MemoryShadowFixture
    ) async throws -> MemoryShadowQualificationReport
}

struct MemoryShadowFixture {
    let memories: [MemoryShadowMemoryFixture]
    let queries: [MemoryShadowQueryFixture]
}

struct MemoryShadowMemoryFixture: Hashable {
    let memoryID: String
    /// The only memory field exposed to the shadow runtime.
    let displayText: String
}

struct MemoryShadowQueryFixture: Hashable {
    let queryID: String
    let locale: String
    let expectedMemoryID: String
    let displayText: String
}

struct MemoryShadowLocaleMetrics: Codable, Equatable {
    let correct: Int
    let total: Int

    var accuracy: Double {
        guard total > 0 else { return 0 }
        return Double(correct) / Double(total)
    }
}

struct MemoryShadowPrediction: Codable, Equatable {
    let queryID: String
    let locale: String
    let expectedMemoryID: String
    let predictedMemoryID: String
    let correct: Bool
    let topCosineSimilarity: Float
    let topOneMargin: Float
}

/// Report-only output. Nothing in this type can be fed into app state or a
/// command transport without a new, explicit production integration.
struct MemoryShadowQualificationReport: Codable, Equatable {
    let queryCount: Int
    let correctCount: Int
    let recallAtOne: Double
    let p50Seconds: Double
    let p95Seconds: Double
    let minimumTopOneMargin: Float
    let localeMetrics: [String: MemoryShadowLocaleMetrics]
    let predictions: [MemoryShadowPrediction]
}

enum MemoryShadowQualificationError: Error, Equatable {
    case emptyMemories
    case emptyQueries
    case duplicateMemoryID(String)
    case missingEmbedding(expected: Int, actual: Int)
    case invalidEmbeddingDimensions
    case zeroMagnitudeEmbedding
}

/// Real multilingual-E5 qualification implementation. It is deliberately
/// target-only and cannot be constructed by the production application.
final class MultilingualE5ReadOnlyShadow: MemoryShadowQualificationReporting {
    typealias EmbeddingFunction = ([String]) async -> [[Float]]

    private let embed: EmbeddingFunction
    private let now: () -> TimeInterval

    init(
        embed: @escaping EmbeddingFunction,
        now: @escaping () -> TimeInterval = { CFAbsoluteTimeGetCurrent() }
    ) {
        self.embed = embed
        self.now = now
    }

    convenience init(container: EmbedderModelContainer) {
        self.init { texts in
            await container.perform { context -> [[Float]] in
                let encoded = texts.map {
                    context.tokenizer.encode(text: $0, addSpecialTokens: true)
                }
                let maximumLength = encoded.reduce(into: 16) { current, tokens in
                    current = max(current, tokens.count)
                }
                let paddingToken = context.tokenizer.convertTokenToId("<pad>") ?? 0
                let padded = stacked(encoded.map { tokens in
                    MLXArray(
                        tokens + Array(
                            repeating: paddingToken,
                            count: maximumLength - tokens.count
                        )
                    )
                })
                let attentionMask = padded .!= paddingToken
                let tokenTypes = MLXArray.zeros(like: padded)
                let output = context.pooling(
                    context.model(
                        padded,
                        positionIds: nil,
                        tokenTypeIds: tokenTypes,
                        attentionMask: attentionMask
                    ),
                    normalize: true,
                    applyLayerNorm: false
                )
                output.eval()
                return output.map { $0.asArray(Float.self) }
            }
        }
    }

    func makeReport(
        fixture: MemoryShadowFixture
    ) async throws -> MemoryShadowQualificationReport {
        guard !fixture.memories.isEmpty else {
            throw MemoryShadowQualificationError.emptyMemories
        }
        guard !fixture.queries.isEmpty else {
            throw MemoryShadowQualificationError.emptyQueries
        }
        var memoryIDs = Set<String>()
        for memory in fixture.memories where !memoryIDs.insert(memory.memoryID).inserted {
            throw MemoryShadowQualificationError.duplicateMemoryID(memory.memoryID)
        }

        let memoryVectors = await embed(
            fixture.memories.map { "passage: \($0.displayText)" }
        )
        guard memoryVectors.count == fixture.memories.count else {
            throw MemoryShadowQualificationError.missingEmbedding(
                expected: fixture.memories.count,
                actual: memoryVectors.count
            )
        }

        var correctCount = 0
        var localeMetrics: [String: MemoryShadowLocaleMetrics] = [:]
        var latencies: [Double] = []
        var margins: [Float] = []
        var predictions: [MemoryShadowPrediction] = []

        for query in fixture.queries {
            let started = now()
            let queryVectors = await embed(["query: \(query.displayText)"])
            latencies.append(now() - started)
            guard let queryVector = queryVectors.first else {
                throw MemoryShadowQualificationError.missingEmbedding(
                    expected: 1,
                    actual: queryVectors.count
                )
            }

            let scored = try zip(fixture.memories, memoryVectors)
                .map { memory, vector in
                    (
                        memory.memoryID,
                        try Self.cosineSimilarity(queryVector, vector)
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
                    return lhs.1 > rhs.1
                }
            guard let predicted = scored.first else {
                throw MemoryShadowQualificationError.emptyMemories
            }
            let secondScore = scored.dropFirst().first?.1 ?? predicted.1
            let margin = predicted.1 - secondScore
            margins.append(margin)

            let correct = predicted.0 == query.expectedMemoryID
            if correct { correctCount += 1 }
            let previous = localeMetrics[query.locale]
                ?? MemoryShadowLocaleMetrics(correct: 0, total: 0)
            localeMetrics[query.locale] = MemoryShadowLocaleMetrics(
                correct: previous.correct + (correct ? 1 : 0),
                total: previous.total + 1
            )
            predictions.append(
                MemoryShadowPrediction(
                    queryID: query.queryID,
                    locale: query.locale,
                    expectedMemoryID: query.expectedMemoryID,
                    predictedMemoryID: predicted.0,
                    correct: correct,
                    topCosineSimilarity: predicted.1,
                    topOneMargin: margin
                )
            )
        }

        return MemoryShadowQualificationReport(
            queryCount: fixture.queries.count,
            correctCount: correctCount,
            recallAtOne: Double(correctCount) / Double(fixture.queries.count),
            p50Seconds: Self.percentile(latencies, percentile: 0.50),
            p95Seconds: Self.percentile(latencies, percentile: 0.95),
            minimumTopOneMargin: margins.min() ?? 0,
            localeMetrics: localeMetrics,
            predictions: predictions
        )
    }

    private static func cosineSimilarity(
        _ lhs: [Float],
        _ rhs: [Float]
    ) throws -> Float {
        guard !lhs.isEmpty, lhs.count == rhs.count else {
            throw MemoryShadowQualificationError.invalidEmbeddingDimensions
        }
        var dot: Float = 0
        var lhsSquared: Float = 0
        var rhsSquared: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsSquared += lhs[index] * lhs[index]
            rhsSquared += rhs[index] * rhs[index]
        }
        let denominator = sqrt(lhsSquared) * sqrt(rhsSquared)
        guard denominator > 0 else {
            throw MemoryShadowQualificationError.zeroMagnitudeEmbedding
        }
        return dot / denominator
    }

    private static func percentile(
        _ values: [Double],
        percentile: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
