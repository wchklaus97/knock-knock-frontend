import Foundation

/// The only Memory fields the in-app shadow may receive.
struct MemoryShadowInput: Equatable, Sendable {
    let memoryID: String
    let displayText: String
}

/// Host-side scheduler. Implementations must not mutate UI, Command, ranking,
/// or Memory cache. The default Release path is a no-op.
protocol MemoryShadowEvaluating: AnyObject, Sendable {
    func evaluate(memories: [MemoryShadowInput])
    func cancel()
}

enum MemoryShadowCacheFiles {
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

    static func writeHostDebug(_ payload: [String: Any]) {
        guard let directory,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
              )
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(
            to: directory.appendingPathComponent("memory-shadow-host.json"),
            options: .atomic
        )
    }
}

final class NoOpMemoryShadowEvaluator: MemoryShadowEvaluating, @unchecked Sendable {
    func evaluate(memories: [MemoryShadowInput]) {}
    func cancel() {}
}

/// Debug/Staging loader. Release compilation drops the body so the app binary
/// does not reference the iOS 17 MLX framework.
final class BundledMLXMemoryShadowEvaluator: MemoryShadowEvaluating, @unchecked Sendable {
    func evaluate(memories: [MemoryShadowInput]) {
        #if DEBUG
        guard #available(iOS 17.0, *) else {
            MemoryShadowCacheFiles.writeHostDebug(
                ["stage": "unsupported-os", "count": memories.count]
            )
            return
        }
        guard !memories.isEmpty else { return }
        MemoryShadowCacheFiles.writeHostDebug(["stage": "start", "count": memories.count])
        guard let runtime = Self.loadRuntimeClass() else {
            MemoryShadowCacheFiles.writeHostDebug(
                ["stage": "runtime-missing", "count": memories.count]
            )
            return
        }
        guard let json = Self.encode(memories) else {
            MemoryShadowCacheFiles.writeHostDebug(
                ["stage": "encode-failed", "count": memories.count]
            )
            return
        }
        let selector = NSSelectorFromString("evaluateDisplayTextsJSON:")
        let object = runtime as AnyObject
        guard object.responds(to: selector) else {
            MemoryShadowCacheFiles.writeHostDebug(
                ["stage": "selector-missing", "count": memories.count]
            )
            return
        }
        _ = object.perform(selector, with: json)
        MemoryShadowCacheFiles.writeHostDebug(
            [
                "stage": "invoked",
                "count": memories.count,
                "jsonBytes": json.length,
            ]
        )
        #endif
    }

    func cancel() {
        #if DEBUG
        if #available(iOS 17.0, *) {
            let selector = NSSelectorFromString("cancelEvaluation")
            if let runtime = Self.loadRuntimeClass() as AnyObject?,
               runtime.responds(to: selector)
            {
                _ = runtime.perform(selector)
            }
        }
        #endif
    }

    #if DEBUG
    private static func encode(_ memories: [MemoryShadowInput]) -> NSString? {
        let payload: [[String: String]] = memories.map {
            ["memoryID": $0.memoryID, "displayText": $0.displayText]
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json as NSString
    }

    private static func loadRuntimeClass() -> AnyClass? {
        NSClassFromString("KKMemoryShadowRuntime")
    }
    #endif
}
