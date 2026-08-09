import CryptoKit
import XCTest
@testable import VoiceAgentBridge

final class ModelArtifactStoreTests: XCTestCase {
    func testFileInstallVerifiesBeforeActivationAndPersistsManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-store-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("signed-model-artifact".utf8)
        try bytes.write(to: source, options: .atomic)
        let privateKey = Curve25519.Signing.PrivateKey()
        let digest = Data(SHA256.hash(data: bytes))
        let manifest = try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            signature: try privateKey.signature(for: digest),
            sizeBytes: UInt64(bytes.count),
            minimumCapability: "cpu-v1"
        )
        let verifier = try Ed25519ModelArtifactVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let selector = RollbackSafeModelSelector(
            verifier: verifier,
            capabilities: DeclaredModelCapabilities(identifiers: ["cpu-v1"])
        )
        let store = SignedModelArtifactStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            selector: selector
        )

        let installed = try await store.install(
            SignedModelArtifactDescriptor(manifest: manifest, downloadURL: source)
        )

        XCTAssertEqual(selector.activeModel, installed)
        XCTAssertEqual(try Data(contentsOf: installed.artifactURL), bytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installed.artifactURL.appendingPathExtension("manifest").path
            )
        )
    }

    func testFailedInstallDoesNotActivateCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-store-failure-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("tampered-model-artifact".utf8)
        try bytes.write(to: source, options: .atomic)
        let signingKey = Curve25519.Signing.PrivateKey()
        let wrongKey = Curve25519.Signing.PrivateKey()
        let digest = Data(SHA256.hash(data: bytes))
        let manifest = try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            signature: try wrongKey.signature(for: digest),
            sizeBytes: UInt64(bytes.count),
            minimumCapability: "cpu-v1"
        )
        let selector = RollbackSafeModelSelector(
            verifier: try Ed25519ModelArtifactVerifier(
                publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation
            ),
            capabilities: DeclaredModelCapabilities(identifiers: ["cpu-v1"])
        )
        let store = SignedModelArtifactStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            selector: selector
        )

        do {
            _ = try await store.install(
                SignedModelArtifactDescriptor(manifest: manifest, downloadURL: source)
            )
            XCTFail("A signature mismatch must prevent activation")
        } catch let error as ModelArtifactVerificationError {
            XCTAssertEqual(error, .signatureMismatch)
        }
        XCTAssertNil(selector.activeModel)
        XCTAssertNil(selector.rollbackModel)
    }

    func testModelManagerRejectsNonHTTPSDescriptor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let signingKey = Curve25519.Signing.PrivateKey()
        let manager = try LocalVoiceModelManager(
            rootURL: root,
            publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )
        let manifest = try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: String(repeating: "0", count: 64),
            signature: Data([1]),
            sizeBytes: 1,
            minimumCapability: "cpu-v1"
        )
        let descriptor = ModelArtifactDescriptorResponse(
            model_id: "gemma-command",
            manifest: manifest,
            download_url: "http://localhost/model.litertlm",
            expires_at: nil
        )

        do {
            _ = try await manager.install(descriptor)
            XCTFail("The model manager must reject non-HTTPS artifact URLs")
        } catch let error as LocalVoiceModelManagerError {
            XCTAssertEqual(error, .invalidDownloadURL)
        }
    }
}
