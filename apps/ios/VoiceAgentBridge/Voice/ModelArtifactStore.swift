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
    case invalidDownloadURL
    case unsafeRedirect
    case invalidHTTPResponse
    case unexpectedHTTPStatus(Int)
    case downloadEmpty
    case downloadSizeMismatch(expected: UInt64, actual: UInt64)
}

private struct PersistedModelSelection: Codable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let activeArtifact: String?
    let rollbackArtifact: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case activeArtifact = "active_artifact"
        case rollbackArtifact = "rollback_artifact"
    }

    init(activeArtifact: String?, rollbackArtifact: String?) {
        schemaVersion = Self.supportedSchemaVersion
        self.activeArtifact = activeArtifact
        self.rollbackArtifact = rollbackArtifact
    }
}

/// Downloads signed artifacts into Application Support and activates them only
/// after verification. A failed download or verification leaves the active and
/// rollback selections unchanged. The backend/CDN supplies the descriptor; no
/// gated model URL or access token is embedded in the app.
final class SignedModelArtifactStore {
    private static let selectionStateFileName = ".selection.v1.json"

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
        let manifestURL = targetURL.appendingPathExtension("manifest")
        if fileManager.fileExists(atPath: targetURL.path) {
            let existing = InstalledModel(manifest: descriptor.manifest, artifactURL: targetURL)
            do {
                try persistManifest(descriptor.manifest, at: manifestURL)
                try activateAndPersist(existing)
                return existing
            } catch is ModelArtifactVerificationError {
                try? fileManager.removeItem(at: targetURL)
                try? fileManager.removeItem(at: manifestURL)
            } catch {
                throw error
            }
        }

        let temporaryURL = rootURL.appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try await download(descriptor, to: temporaryURL)
        let stagedURL = rootURL.appendingPathComponent(".staged-\(UUID().uuidString)")
        try fileManager.moveItem(at: temporaryURL, to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }

        try fileManager.moveItem(at: stagedURL, to: targetURL)
        do {
            try persistManifest(descriptor.manifest, at: manifestURL)
        } catch {
            try? fileManager.removeItem(at: targetURL)
            throw error
        }
        let candidate = InstalledModel(manifest: descriptor.manifest, artifactURL: targetURL)
        do {
            try activateAndPersist(candidate)
            return candidate
        } catch {
            try? fileManager.removeItem(at: targetURL)
            try? fileManager.removeItem(at: manifestURL)
            throw error
        }
    }

    /// Rebuilds selection from the persisted active/rollback order, verifying
    /// both artifacts before exposing either. Missing or invalid state falls
    /// back to the two highest-precedence verified installed models.
    @discardableResult
    func restoreInstalledSelection() -> InstalledModel? {
        let candidates = installedModels()
        let candidatesByName = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.artifactURL.lastPathComponent, $0) }
        )

        if let persisted = loadSelection(),
           persisted.schemaVersion == PersistedModelSelection.supportedSchemaVersion,
           persisted.activeArtifact != nil || candidates.isEmpty
        {
            let active = persisted.activeArtifact.flatMap { candidatesByName[$0] }
            let rollback = persisted.rollbackArtifact.flatMap { candidatesByName[$0] }
            if (persisted.activeArtifact == nil || active != nil),
               (persisted.rollbackArtifact == nil || rollback != nil)
            {
                do {
                    try selector.restoreVerifiedSelection(
                        activeModel: active,
                        rollbackModel: rollback
                    )
                    try? persistSelection()
                    return selector.activeModel
                } catch {
                    // A local state file is only a hint. Never restore either entry
                    // until the signed manifests and artifact bytes verify again.
                }
            }
        }

        let active = selector.activateBestVerified(from: candidates)
        try? persistSelection()
        return active
    }

    func persistSelection() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let state = PersistedModelSelection(
            activeArtifact: selector.activeModel?.artifactURL.lastPathComponent,
            rollbackArtifact: selector.rollbackModel?.artifactURL.lastPathComponent
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: selectionStateURL, options: .atomic)
    }

    private func download(_ descriptor: SignedModelArtifactDescriptor, to destination: URL) async throws {
        if descriptor.downloadURL.isFileURL {
            try validateDownloadedFile(at: descriptor.downloadURL, manifest: descriptor.manifest)
            try fileManager.copyItem(at: descriptor.downloadURL, to: destination)
            return
        }

        guard Self.isSafeHTTPSURL(descriptor.downloadURL) else {
            throw ModelArtifactStoreError.invalidDownloadURL
        }

        var request = URLRequest(url: descriptor.downloadURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Model packages are hundreds of megabytes. The default release path
        // waits for ordinary Wi-Fi instead of silently consuming a metered or
        // Low Data Mode connection; an explicit future UX may offer override.
        request.allowsExpensiveNetworkAccess = false
        request.allowsConstrainedNetworkAccess = false
        for (header, value) in descriptor.headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let authorizationHeader = request.value(forHTTPHeaderField: "Authorization")
        let delegate = ModelDownloadDelegate(
            originalURL: descriptor.downloadURL,
            authorizationHeader: authorizationHeader,
            expectedSize: descriptor.manifest.sizeBytes
        )
        let configuration = session.configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let downloadSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { downloadSession.invalidateAndCancel() }
        // A Gemma artifact can be hundreds of megabytes. URLSession's download
        // API streams to a temporary file instead of retaining the full model
        // in process memory on iPhone 13-class devices.
        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await downloadSession.download(for: request)
        } catch {
            if let policyFailure = delegate.failure {
                throw policyFailure
            }
            throw error
        }
        if let policyFailure = delegate.failure {
            throw policyFailure
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelArtifactStoreError.invalidHTTPResponse
        }
        guard let responseURL = httpResponse.url,
              Self.isSafeHTTPSURL(responseURL),
              authorizationHeader == nil
                || Self.sameOrigin(descriptor.downloadURL, responseURL)
        else {
            throw ModelArtifactStoreError.unsafeRedirect
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ModelArtifactStoreError.unexpectedHTTPStatus(httpResponse.statusCode)
        }
        try validateDownloadedFile(at: downloadedURL, manifest: descriptor.manifest)
        try fileManager.moveItem(at: downloadedURL, to: destination)
    }

    private func activateAndPersist(_ candidate: InstalledModel) throws {
        let previousSelection = selector.selectionSnapshot
        do {
            try selector.activate(candidate)
            try persistSelection()
        } catch {
            selector.restoreKnownVerifiedSelection(previousSelection)
            throw error
        }
    }

    private func persistManifest(_ manifest: ModelManifest, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func installedModels() -> [InstalledModel] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files.compactMap { manifestURL -> InstalledModel? in
            guard manifestURL.pathExtension == "manifest",
                  let values = try? manifestURL.resourceValues(
                      forKeys: [.fileSizeKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= 64 * 1024,
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? ModelManifest.decodeStrict(from: data)
            else {
                return nil
            }
            let artifactURL = manifestURL.deletingPathExtension()
            guard artifactURL.lastPathComponent == Self.fileName(for: manifest),
                  fileManager.fileExists(atPath: artifactURL.path)
            else {
                return nil
            }
            return InstalledModel(manifest: manifest, artifactURL: artifactURL)
        }
    }

    private func loadSelection() -> PersistedModelSelection? {
        guard let values = try? selectionStateURL.resourceValues(
                  forKeys: [.fileSizeKey, .isRegularFileKey]
              ),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 4 * 1024,
              let data = try? Data(contentsOf: selectionStateURL)
        else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedModelSelection.self, from: data)
    }

    private func validateDownloadedFile(at url: URL, manifest: ModelManifest) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value, size > 0 else {
            throw ModelArtifactStoreError.downloadEmpty
        }
        guard size <= ModelManifest.maximumArtifactSizeBytes,
              size == manifest.sizeBytes
        else {
            throw ModelArtifactStoreError.downloadSizeMismatch(
                expected: manifest.sizeBytes,
                actual: size
            )
        }
    }

    private var selectionStateURL: URL {
        rootURL.appendingPathComponent(Self.selectionStateFileName)
    }

    static func redirectedRequest(
        _ proposedRequest: URLRequest,
        originalURL: URL,
        authorizationHeader: String?
    ) -> URLRequest? {
        guard let redirectURL = proposedRequest.url,
              isSafeHTTPSURL(redirectURL)
        else {
            return nil
        }

        var redirected = proposedRequest
        if let authorizationHeader {
            guard sameOrigin(originalURL, redirectURL) else { return nil }
            redirected.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        } else {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return redirected
    }

    private static func isSafeHTTPSURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : nil
    }

    static func fileName(for manifest: ModelManifest) -> String {
        "\(manifest.modelID)-\(manifest.modelVersion).litertlm"
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let originalURL: URL
    private let authorizationHeader: String?
    private let expectedSize: UInt64
    private let lock = NSLock()
    private var recordedFailure: ModelArtifactStoreError?

    init(originalURL: URL, authorizationHeader: String?, expectedSize: UInt64) {
        self.originalURL = originalURL
        self.authorizationHeader = authorizationHeader
        self.expectedSize = expectedSize
    }

    var failure: ModelArtifactStoreError? {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailure
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirected = SignedModelArtifactStore.redirectedRequest(
            request,
            originalURL: originalURL,
            authorizationHeader: authorizationHeader
        ) else {
            record(.unsafeRedirect)
            completionHandler(nil)
            return
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let written = UInt64(max(0, totalBytesWritten))
        let expected = UInt64(max(0, totalBytesExpectedToWrite))
        guard written > expectedSize || expected > expectedSize else { return }
        record(.downloadSizeMismatch(
            expected: expectedSize,
            actual: max(written, expected)
        ))
        downloadTask.cancel()
    }

    private func record(_ failure: ModelArtifactStoreError) {
        lock.lock()
        if recordedFailure == nil {
            recordedFailure = failure
        }
        lock.unlock()
    }
}
