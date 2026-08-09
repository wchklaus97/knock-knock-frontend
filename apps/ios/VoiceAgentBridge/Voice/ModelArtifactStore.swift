import Foundation

/// A model manifest is trusted metadata; the URL is only a transport location.
/// The artifact is not activated until its size, SHA-256 and Ed25519 signature
/// have been verified by RollbackSafeModelSelector.
struct SignedModelArtifactDescriptor {
    let manifest: ModelManifest
    let downloadURL: URL
    let headers: [String: String]

    init(manifest: ModelManifest, downloadURL: URL, headers: [String: String] = [:]) {
        self.manifest = manifest
        self.downloadURL = downloadURL
        self.headers = headers
    }
}

enum ModelArtifactStoreError: Error, Equatable {
    case invalidHTTPResponse
    case unexpectedHTTPStatus(Int)
    case downloadEmpty
}

/// Downloads signed artifacts into Application Support and activates them only
/// after verification. A failed download or verification leaves the active and
/// rollback selections unchanged. The backend/CDN supplies the descriptor; no
/// gated model URL or access token is embedded in the app.
final class SignedModelArtifactStore {
    private let rootURL: URL
    private let selector: RollbackSafeModelSelector
    private let session: URLSession
    private let fileManager: FileManager

    init(
        rootURL: URL,
        selector: RollbackSafeModelSelector,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.selector = selector
        self.session = session
        self.fileManager = fileManager
    }

    @discardableResult
    func install(_ descriptor: SignedModelArtifactDescriptor) async throws -> InstalledModel {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let targetURL = rootURL.appendingPathComponent(Self.fileName(for: descriptor.manifest))
        if fileManager.fileExists(atPath: targetURL.path) {
            let existing = InstalledModel(manifest: descriptor.manifest, artifactURL: targetURL)
            do {
                try selector.activate(existing)
                return existing
            } catch {
                try? fileManager.removeItem(at: targetURL)
            }
        }

        let temporaryURL = rootURL.appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try await download(descriptor, to: temporaryURL)
        let stagedURL = rootURL.appendingPathComponent(".staged-\(UUID().uuidString)")
        try fileManager.moveItem(at: temporaryURL, to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }

        try fileManager.moveItem(at: stagedURL, to: targetURL)
        let manifestURL = targetURL.appendingPathExtension("manifest")
        do {
            let manifestData = try JSONEncoder().encode(descriptor.manifest)
            try manifestData.write(to: manifestURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: targetURL)
            throw error
        }
        let candidate = InstalledModel(manifest: descriptor.manifest, artifactURL: targetURL)
        do {
            try selector.activate(candidate)
            return candidate
        } catch {
            try? fileManager.removeItem(at: targetURL)
            try? fileManager.removeItem(at: manifestURL)
            throw error
        }
    }

    private func download(_ descriptor: SignedModelArtifactDescriptor, to destination: URL) async throws {
        if descriptor.downloadURL.isFileURL {
            try fileManager.copyItem(at: descriptor.downloadURL, to: destination)
            return
        }

        var request = URLRequest(url: descriptor.downloadURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (header, value) in descriptor.headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelArtifactStoreError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ModelArtifactStoreError.unexpectedHTTPStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else { throw ModelArtifactStoreError.downloadEmpty }
        try data.write(to: destination, options: .atomic)
    }

    static func fileName(for manifest: ModelManifest) -> String {
        "\(manifest.modelID)-\(manifest.modelVersion).litertlm"
    }
}
