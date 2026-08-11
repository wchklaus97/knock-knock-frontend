import Foundation

enum LocalVoiceModelManagerError: Error, Equatable {
    case publicKeyNotConfigured
    case invalidPublicKey
    case modelNotInstalled
    case invalidDownloadURL
    case descriptorModelIDMismatch
}

/// Owns the trust root, signed model cache and rollback-safe selection used by
/// the local intent runtime. The public key is a release configuration value,
/// not a server response, so a compromised API cannot replace the trust root.
final class LocalVoiceModelManager {
    static let defaultModelID = "gemma-command"

    private let selector: RollbackSafeModelSelector
    private let store: SignedModelArtifactStore
    private(set) var activeModel: InstalledModel?
    var rollbackModel: InstalledModel? { selector.rollbackModel }

    init(
        rootURL: URL? = nil,
        publicKeyBase64: String? = Bundle.main.object(forInfoDictionaryKey: "KNOCK_MODEL_PUBLIC_KEY_BASE64") as? String,
        session: URLSession = .shared
    ) throws {
        guard let publicKeyBase64,
              !publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let publicKeyData = Data(base64Encoded: publicKeyBase64)
        else {
            throw LocalVoiceModelManagerError.publicKeyNotConfigured
        }
        let verifier: Ed25519ModelArtifactVerifier
        do {
            verifier = try Ed25519ModelArtifactVerifier(publicKeyRawRepresentation: publicKeyData)
        } catch {
            throw LocalVoiceModelManagerError.invalidPublicKey
        }

        let resolvedRoot = rootURL ?? Self.defaultRootURL()
        selector = RollbackSafeModelSelector(
            verifier: verifier,
            capabilities: DeclaredModelCapabilities(identifiers: ["cpu-v1", "gpu-v1", "ane-v1"])
        )
        store = SignedModelArtifactStore(rootURL: resolvedRoot, selector: selector, session: session)
        activeModel = store.restoreInstalledSelection()
    }

    func install(
        _ descriptor: ModelArtifactDescriptorResponse,
        authorizationToken: String? = nil,
        trustedAPIBaseURL: URL? = nil
    ) async throws -> InstalledModel {
        guard descriptor.model_id == Self.defaultModelID,
              descriptor.manifest.modelID == Self.defaultModelID,
              descriptor.model_id == descriptor.manifest.modelID
        else {
            throw LocalVoiceModelManagerError.descriptorModelIDMismatch
        }
        guard let url = URL(string: descriptor.download_url),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil
        else {
            throw LocalVoiceModelManagerError.invalidDownloadURL
        }
        let signedDescriptor = SignedModelArtifactDescriptor(
            manifest: descriptor.manifest,
            downloadURL: url,
            headers: Self.authorizationHeaders(
                downloadURL: url,
                trustedAPIBaseURL: trustedAPIBaseURL,
                token: authorizationToken
            )
        )
        let installed = try await store.install(signedDescriptor)
        activeModel = installed
        return installed
    }

    func makeCommandGenerator(
        useGPU: Bool = true,
        locale: Locale = .current,
        timezone: TimeZone = .current,
        deviceID: String? = nil,
        sessionID: String? = nil
    ) throws -> GemmaCommandGenerator {
        guard let activeModel else {
            throw LocalVoiceModelManagerError.modelNotInstalled
        }
        return try GemmaCommandGenerator(
            modelURL: activeModel.artifactURL,
            modelVersion: activeModel.manifest.modelVersion,
            useGPU: useGPU,
            locale: locale,
            timezone: timezone,
            deviceID: deviceID,
            sessionID: sessionID
        )
    }

    @discardableResult
    func rollback() throws -> InstalledModel {
        let previousSelection = selector.selectionSnapshot
        do {
            let model = try selector.rollback()
            try store.persistSelection()
            activeModel = model
            return model
        } catch {
            selector.restoreKnownVerifiedSelection(previousSelection)
            throw error
        }
    }

    private static func defaultRootURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("KnockKnock", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Bearer credentials are attached only to an HTTPS URL on the exact API
    /// origin. Public CDN URLs remain credential-free, preventing a descriptor
    /// from forwarding the user's session token to another host.
    static func authorizationHeaders(
        downloadURL: URL,
        trustedAPIBaseURL: URL?,
        token: String?
    ) -> [String: String] {
        guard let trustedAPIBaseURL,
              let token = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              downloadURL.scheme?.lowercased() == "https",
              trustedAPIBaseURL.scheme?.lowercased() == "https",
              downloadURL.host?.isEmpty == false,
              trustedAPIBaseURL.host?.isEmpty == false,
              downloadURL.user == nil,
              downloadURL.password == nil,
              trustedAPIBaseURL.user == nil,
              trustedAPIBaseURL.password == nil,
              downloadURL.host?.lowercased() == trustedAPIBaseURL.host?.lowercased(),
              effectivePort(downloadURL) == effectivePort(trustedAPIBaseURL)
        else {
            return [:]
        }
        return ["Authorization": "Bearer \(token)"]
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
