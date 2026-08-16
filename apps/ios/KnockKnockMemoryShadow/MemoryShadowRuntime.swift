import CryptoKit
import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import os.log
import Tokenizers

/// In-app Objective-C entry for Debug/Staging. The main application must not
/// import this module; it loads the class by name so Release can omit the
/// framework entirely.
@available(iOS 17.0, *)
@objc(KKMemoryShadowRuntime)
public final class MemoryShadowRuntime: NSObject {
    public static let expectedE5ModelSHA256 =
        "1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477"

    private static let logger = Logger(
        subsystem: "hk.knockknock.app",
        category: "memory-shadow"
    )
    private static var evaluateTask: Task<Void, Never>?
    private static var lastSignature: String?

    @objc(evaluateDisplayTextsJSON:)
    public static func evaluateDisplayTextsJSON(_ json: NSString) {
        writeDebug(["stage": "json-entered", "jsonBytes": json.length])
        let inputs = decode(json)
        writeDebug(["stage": "json-decoded", "count": inputs.count])
        schedule(inputs)
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

    private static func decode(_ json: NSString) -> [MemoryShadowMemoryFixture] {
        guard let data = (json as String).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return raw.compactMap { item in
            let dictionary = (item as? [String: Any])
                ?? (item as? NSDictionary as? [String: Any])
            guard let memoryID = dictionary?["memoryID"] as? String,
                  let displayText = dictionary?["displayText"] as? String
            else { return nil }
            return MemoryShadowMemoryFixture(memoryID: memoryID, displayText: displayText)
        }
    }

    private static func schedule(_ inputs: [MemoryShadowMemoryFixture]) {
        let signature = inputs.map(\.memoryID).sorted().joined(separator: ",")
        if evaluateTask != nil, lastSignature == signature {
            writeDebug(["stage": "already-running", "count": inputs.count])
            return
        }
        lastSignature = signature
        evaluateTask = Task.detached(priority: .userInitiated) {
            await run(memories: inputs)
        }
    }

    private static func writeDebug(_ payload: [String: Any]) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let directory = caches?.appendingPathComponent("KnockKnock", isDirectory: true) else {
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
              )
        else { return }
        try? data.write(
            to: directory.appendingPathComponent("memory-shadow-debug.json"),
            options: .atomic
        )
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
            let sha = try weightSHA256(in: directory)
            guard sha == expectedE5ModelSHA256 else {
                writeDebug(["stage": "sha-mismatch"])
                logger.error("Skipping in-app E5 shadow; weight SHA-256 did not match the pin.")
                return
            }
            writeDebug(["stage": "loading-model", "count": memories.count])
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
            writeDebug(["stage": "model-loaded", "count": memories.count])
            let shadow = MultilingualE5ReadOnlyShadow(container: container)
            let queries = memories.map { memory in
                MemoryShadowQueryFixture(
                    queryID: "self-\(memory.memoryID)",
                    locale: "und",
                    expectedMemoryID: memory.memoryID,
                    displayText: memory.displayText
                )
            }
            let report = try await shadow.makeReport(
                fixture: MemoryShadowFixture(memories: memories, queries: queries)
            )
            try write(report)
            writeDebug([
                "stage": "wrote-report",
                "queryCount": report.queryCount,
                "recallAtOne": report.recallAtOne,
            ])
            logger.info(
                "Wrote private E5 shadow report. recall@1=\(report.recallAtOne, privacy: .public)"
            )
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
              isDirectory.boolValue,
              FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("config.json").path
              )
        else { return false }
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
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ report: MemoryShadowQualificationReport) throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let directory = caches?.appendingPathComponent("KnockKnock", isDirectory: true) else {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: directory.appendingPathComponent("memory-shadow-last.json"),
            options: .atomic
        )
    }
}
