import Foundation

enum LocalVoiceModelManagerError: Error, Equatable {
    case publicKeyNotConfigured
    case invalidPublicKey
    case modelNotInstalled
    case invalidDownloadURL
}

/// Owns the trust root, signed model cache and rollback-safe selection used by
/// the local intent runtime. The public key is a release configuration value,
/// not a server response, so a compromised API cannot replace the trust root.
final class LocalVoiceModelManager {
    static let defaultModelID = "gemma-command"

    private let selector: RollbackSafeModelSelector
    private let store: SignedModelArtifactStore
    private(set) var activeModel: InstalledModel?

    init(
        rootURL: URL? = nil,
        publicKeyBase64: String? = Bundle.main.object(forInfoDictionaryKey: "KNOCK_MODEL_PUBLIC_KEY_BASE64") as? String
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
        store = SignedModelArtifactStore(rootURL: resolvedRoot, selector: selector)
        restoreInstalledModels(from: resolvedRoot)
    }

    func install(_ descriptor: ModelArtifactDescriptorResponse) async throws -> InstalledModel {
        guard let url = URL(string: descriptor.download_url) else {
            throw LocalVoiceModelManagerError.invalidDownloadURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw LocalVoiceModelManagerError.invalidDownloadURL
        }
        let signedDescriptor = SignedModelArtifactDescriptor(
            manifest: descriptor.manifest,
            downloadURL: url
        )
        let installed = try await store.install(signedDescriptor)
        activeModel = installed
        return installed
    }

    func makeCommandGenerator(useGPU: Bool = true) throws -> GemmaCommandGenerator {
        guard let activeModel else {
            throw LocalVoiceModelManagerError.modelNotInstalled
        }
        return try GemmaCommandGenerator(modelURL: activeModel.artifactURL, useGPU: useGPU)
    }

    @discardableResult
    func rollback() throws -> InstalledModel {
        let model = try selector.rollback()
        activeModel = model
        return model
    }

    private func restoreInstalledModels(from rootURL: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let candidates = files.compactMap { manifestURL -> InstalledModel? in
            guard manifestURL.pathExtension == "manifest" else { return nil }
            let artifactURL = manifestURL.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: artifactURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? ModelManifest.decodeStrict(from: data)
            else {
                return nil
            }
            return InstalledModel(manifest: manifest, artifactURL: artifactURL)
        }
        activeModel = selector.activateBestVerified(from: candidates)
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
}
