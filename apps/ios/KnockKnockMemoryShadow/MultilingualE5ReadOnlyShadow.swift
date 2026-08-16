import Foundation
import MLX
import MLXEmbedders

/// Real multilingual-E5 shadow implementation. It cannot mutate Memory, UI,
/// CommandEnvelope, ranking, or execution.
public final class MultilingualE5ReadOnlyShadow: MemoryShadowQualificationReporting, Sendable {
    public typealias EmbeddingFunction = @Sendable ([String]) async -> [[Float]]

    private let embed: EmbeddingFunction
    private let now: @Sendable () -> TimeInterval

    public init(
        embed: @escaping EmbeddingFunction,
        now: @escaping @Sendable () -> TimeInterval = { CFAbsoluteTimeGetCurrent() }
    ) {
        self.embed = embed
        self.now = now
    }

    public convenience init(container: EmbedderModelContainer) {
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

    public func makeReport(
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
