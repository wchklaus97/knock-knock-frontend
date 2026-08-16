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
}

final class NoOpMemoryShadowEvaluator: MemoryShadowEvaluating, @unchecked Sendable {
    func evaluate(memories: [MemoryShadowInput]) {}
}

/// Debug/Staging loader. Release compilation drops the body so the app binary
/// does not reference the iOS 17 MLX framework.
final class BundledMLXMemoryShadowEvaluator: MemoryShadowEvaluating, @unchecked Sendable {
    func evaluate(memories: [MemoryShadowInput]) {
        #if DEBUG
        guard #available(iOS 17.0, *) else {
            Self.writeHostDebug(["stage": "unsupported-os", "count": memories.count])
            return
        }
        guard !memories.isEmpty else { return }
        Self.writeHostDebug(["stage": "start", "count": memories.count])
        guard let runtime = Self.loadRuntimeClass() else {
            Self.writeHostDebug(["stage": "runtime-missing", "count": memories.count])
            return
        }
        guard let json = Self.encode(memories) else {
            Self.writeHostDebug(["stage": "encode-failed", "count": memories.count])
            return
        }
        let selector = NSSelectorFromString("evaluateDisplayTextsJSON:")
        let object = runtime as AnyObject
        guard object.responds(to: selector) else {
            Self.writeHostDebug(["stage": "selector-missing", "count": memories.count])
            return
        }
        _ = object.perform(selector, with: json)
        Self.writeHostDebug(["stage": "invoked", "count": memories.count, "jsonBytes": json.length])
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

    private static func writeHostDebug(_ payload: [String: Any]) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let directory = caches.appendingPathComponent("KnockKnock", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
              )
        else { return }
        try? data.write(
            to: directory.appendingPathComponent("memory-shadow-host.json"),
            options: .atomic
        )
    }

    private static func loadRuntimeClass() -> AnyClass? {
        if let existing = NSClassFromString("KKMemoryShadowRuntime") {
            return existing
        }
        let candidates: [URL?] = [
            Bundle.main.privateFrameworksURL?
                .appendingPathComponent("KnockKnockMemoryShadow.framework"),
            Bundle.main.bundleURL
                .appendingPathComponent("Frameworks/KnockKnockMemoryShadow.framework"),
        ]
        for url in candidates.compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            guard let bundle = Bundle(url: url) else { continue }
            do {
                if !bundle.isLoaded {
                    try bundle.loadAndReturnError()
                }
            } catch {
                writeHostDebug([
                    "stage": "bundle-load-failed",
                    "path": url.path,
                    "error": error.localizedDescription,
                ])
                continue
            }
            if let loaded = NSClassFromString("KKMemoryShadowRuntime") {
                return loaded
            }
            writeHostDebug(["stage": "class-missing-after-load", "path": url.path])
        }
        return nil
    }
    #endif
}
