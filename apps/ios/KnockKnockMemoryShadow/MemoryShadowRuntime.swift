import CryptoKit
import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers
import os.log

/// In-app Objective-C entry for Debug/Staging. The main application must not
/// import this module; it loads the class by name so Release can omit the
/// framework entirely.
@available(iOS 17.0, *)
@objc(KKMemoryShadowRuntime)
public final class MemoryShadowRuntime: NSObject {
    public static let expectedE5ModelSHA256 =
        "1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477"
    public static let maxMemoriesPerRun = 32

    private static let logger = Logger(
        subsystem: "hk.knockknock.app",
        category: "memory-shadow"
    )
    private static let gate = EvaluationGate()

    public enum JSONError: Error, Equatable, Sendable {
        case invalidPayload
    }

    public static func parseDisplayTextsJSON(_ json: NSString) throws -> [MemoryShadowMemoryFixture] {
        guard let data = (json as String).data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw JSONError.invalidPayload
        }
        var parsed: [MemoryShadowMemoryFixture] = []
        parsed.reserveCapacity(raw.count)
        for item in raw {
            let dictionary = (item as? [String: Any])
                ?? (item as? NSDictionary as? [String: Any])
            guard let memoryID = dictionary?["memoryID"] as? String,
                  let displayText = dictionary?["displayText"] as? String
            else {
                throw JSONError.invalidPayload
            }
            parsed.append(MemoryShadowMemoryFixture(memoryID: memoryID, displayText: displayText))
        }
        return parsed
    }

    public static func signature(for memories: [MemoryShadowMemoryFixture]) -> String {
        memories
            .map { "\($0.memoryID)\u{1e}\($0.displayText)" }
            .sorted()
            .joined(separator: "\n")
    }

    @objc(evaluateDisplayTextsJSON:)
    public static func evaluateDisplayTextsJSON(_ json: NSString) {
        writeDebug(["stage": "json-entered", "jsonBytes": json.length])
        do {
            let inputs = try parseDisplayTextsJSON(json)
            writeDebug(["stage": "json-decoded", "count": inputs.count])
            schedule(inputs)
        } catch {
            writeDebug(["stage": "json-invalid", "jsonBytes": json.length])
        }
    }

    @objc(evaluateDisplayTexts:)
    public static func evaluateDisplayTexts(_ items: NSArray) {
        let inputs: [MemoryShadowMemoryFixture] = items.compactMap { item in
            guard let dictionary = item as? NSDictionary,
                  let memoryID = dictionary["memoryID"] as? String,
                  let displayText = dictionary["displayText"] as? String
            else { return nil }
            return MemoryShadowMemoryFixture(memoryID: memoryID, displayText: displayText)
        }
        schedule(inputs)
    }

    @objc(cancelEvaluation)
    public static func cancelEvaluation() {
        Task { await gate.cancel() }
        writeDebug(["stage": "cancelled-by-host"])
    }

    private static func schedule(_ inputs: [MemoryShadowMemoryFixture]) {
        let signature = signature(for: inputs)
        Task {
            await gate.replace(signature: signature) {
                await run(memories: inputs)
            }
        }
    }

    private static func writeDebug(_ payload: [String: Any]) {
        MemoryShadowReportStore.writeJSON(payload, fileName: "memory-shadow-debug.json")
    }

    private static func run(memories: [MemoryShadowMemoryFixture]) async {
        guard !memories.isEmpty else { return }
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["KNOCK_ALLOW_MLX_SIMULATOR_DIAGNOSTIC"] == "1"
        else {
            writeDebug(["stage": "simulator-skip"])
            logger.debug("Skipping in-app E5 shadow on simulator.")
            return
        }
        #endif
        guard let directory = modelDirectory() else {
            writeDebug(["stage": "weights-missing"])
            logger.debug("Skipping in-app E5 shadow; local weights are absent.")
            return
        }
        do {
            try Task.checkCancellation()
            let sha = try weightSHA256(in: directory)
            guard sha == expectedE5ModelSHA256 else {
                writeDebug(["stage": "sha-mismatch"])
                logger.error("Skipping in-app E5 shadow; weight SHA-256 did not match the pin.")
                return
            }
            try Task.checkCancellation()
            writeDebug(["stage": "loading-model", "count": memories.count])
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
            try Task.checkCancellation()
            writeDebug(["stage": "model-loaded", "count": memories.count])
            let considered = Array(memories.prefix(maxMemoriesPerRun))
            let shadow = MultilingualE5ReadOnlyShadow(container: container)
            let started = CFAbsoluteTimeGetCurrent()
            _ = try await shadow.embedPassages(considered.map(\.displayText))
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            try Task.checkCancellation()
            let report = InAppLatencyReport(
                memoryCount: memories.count,
                consideredCount: considered.count,
                p50Seconds: elapsed,
                p95Seconds: elapsed
            )
            try MemoryShadowReportStore.writeEncodable(
                report,
                fileName: "memory-shadow-last.json"
            )
            writeDebug([
                "stage": "wrote-report",
                "memoryCount": report.memoryCount,
                "consideredCount": report.consideredCount,
            ])
            logger.info("Wrote private E5 shadow latency report.")
        } catch is CancellationError {
            writeDebug(["stage": "cancelled"])
            return
        } catch {
            writeDebug(["stage": "failed", "error": String(describing: error)])
            logger.error("In-app E5 shadow failed without changing app state.")
        }
    }

    private static func modelDirectory() -> URL? {
        let candidates: [URL?] = [
            environmentDirectory(),
            Bundle.main.resourceURL?.appendingPathComponent("e5-small", isDirectory: true),
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("KnockKnock/e5-small", isDirectory: true),
            Bundle(for: MemoryShadowRuntime.self).resourceURL?
                .appendingPathComponent("e5-small", isDirectory: true),
        ]
        return candidates.compactMap { $0 }.first { isValidModelDirectory($0) }
    }

    private static func environmentDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["KNOCK_MLX_EMBEDDER_DIR"],
              !raw.isEmpty,
              !raw.hasPrefix("bundle:")
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private static func isValidModelDirectory(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        let required = ["config.json", "tokenizer.json", "tokenizer_config.json"]
        for name in required {
            guard FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path
            ) else { return false }
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.pathExtension == "safetensors" }.count == 1
    }

    private static func weightSHA256(in directory: URL) throws -> String {
        let weightFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "safetensors" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard weightFiles.count == 1, let weightURL = weightFiles.first else {
            throw MemoryShadowQualificationError.missingEmbedding(expected: 1, actual: weightFiles.count)
        }
        let handle = try FileHandle(forReadingFrom: weightURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@available(iOS 17.0, *)
private actor EvaluationGate {
    private var task: Task<Void, Never>?
    private var signature: String?

    func replace(signature: String, operation: @escaping @Sendable () async -> Void) {
        if task != nil, self.signature == signature {
            MemoryShadowReportStore.writeJSON(
                ["stage": "already-running"],
                fileName: "memory-shadow-debug.json"
            )
            return
        }
        task?.cancel()
        self.signature = signature
        let started = Task.detached(priority: .utility) {
            await operation()
        }
        task = started
        Task {
            _ = await started.result
            await self.clear(if: started)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        signature = nil
    }

    private func clear(if finished: Task<Void, Never>) {
        if task == finished {
            task = nil
        }
    }
}

struct InAppLatencyReport: Codable, Equatable, Sendable {
    let memoryCount: Int
    let consideredCount: Int
    let p50Seconds: Double
    let p95Seconds: Double
}

enum MemoryShadowReportStore {
    static let fileNames = [
        "memory-shadow-last.json",
        "memory-shadow-debug.json",
        "memory-shadow-host.json",
    ]

    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KnockKnock", isDirectory: true)
    }

    static func removeReports() {
        guard let directory else { return }
        for name in fileNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func writeJSON(_ payload: [String: Any], fileName: String) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
              )
        else { return }
        write(data, fileName: fileName)
    }

    static func writeEncodable<T: Encodable>(_ value: T, fileName: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(value), fileName: fileName)
    }

    private static func write(_ data: Data, fileName: String) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }
}
