import CryptoKit
import XCTest
@testable import VoiceAgentBridge

final class ModelManifestTests: XCTestCase {
    func testStrictManifestAndEd25519ArtifactVerification() throws {
        let artifact = Data("small-placeholder-model".utf8)
        let artifactURL = try writeTemporaryArtifact(artifact)
        defer { try? FileManager.default.removeItem(at: artifactURL) }

        let privateKey = Curve25519.Signing.PrivateKey()
        let digest = Data(SHA256.hash(data: artifact))
        let signature = try privateKey.signature(for: digest)
        let manifestJSON = """
        {
          "schema_version": 1,
          "model_id": "gemma-command",
          "model_version": "1.2.0",
          "sha256": "\(hex(digest))",
          "signature": "\(signature.base64EncodedString())",
          "size_bytes": \(artifact.count),
          "minimum_capability": "ane-v1"
        }
        """
        let manifest = try ModelManifest.decodeStrict(from: Data(manifestJSON.utf8))
        let verifier = try Ed25519ModelArtifactVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )

        XCTAssertNoThrow(try verifier.verifyArtifact(at: artifactURL, against: manifest))
        XCTAssertEqual(manifest.modelVersion, "1.2.0")
    }

    func testVerifierRejectsMutatedArtifactAndSignature() throws {
        let original = Data("model-a".utf8)
        let artifactURL = try writeTemporaryArtifact(original)
        defer { try? FileManager.default.removeItem(at: artifactURL) }

        let signingKey = Curve25519.Signing.PrivateKey()
        let wrongKey = Curve25519.Signing.PrivateKey()
        let digest = Data(SHA256.hash(data: original))
        let wrongSignature = try wrongKey.signature(for: digest)
        let manifest = try ModelManifest(
            modelID: "whisper-small",
            modelVersion: "1.0.0",
            sha256: hex(digest),
            signature: wrongSignature,
            sizeBytes: UInt64(original.count),
            minimumCapability: "cpu-v1"
        )
        let verifier = try Ed25519ModelArtifactVerifier(
            publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation
        )
        XCTAssertThrowsError(try verifier.verifyArtifact(at: artifactURL, against: manifest)) { error in
            XCTAssertEqual(error as? ModelArtifactVerificationError, .signatureMismatch)
        }

        try Data("model-b".utf8).write(to: artifactURL, options: .atomic)
        XCTAssertThrowsError(try verifier.verifyArtifact(at: artifactURL, against: manifest)) { error in
            XCTAssertEqual(error as? ModelArtifactVerificationError, .hashMismatch)
        }
    }

    func testManifestRejectsUnknownFieldsAndInvalidMetadata() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data(repeating: 0, count: 32))
        let json = """
        {
          "schema_version": 1,
          "model_id": "gemma",
          "model_version": "latest",
          "sha256": "\(String(repeating: "0", count: 64))",
          "signature": "\(signature.base64EncodedString())",
          "size_bytes": 12,
          "minimum_capability": "ane-v1",
          "download_url": "https://example.invalid/model"
        }
        """
        XCTAssertThrowsError(try ModelManifest.decodeStrict(from: Data(json.utf8)))
    }

    func testSelectionKeepsActiveModelWhenVerificationFailsAndSupportsRollback() throws {
        let old = InstalledModel(
            manifest: try stubManifest(version: "1.0.0", hashCharacter: "a"),
            artifactURL: URL(fileURLWithPath: "/models/old.bin")
        )
        let update = InstalledModel(
            manifest: try stubManifest(version: "2.0.0", hashCharacter: "b"),
            artifactURL: URL(fileURLWithPath: "/models/update.bin")
        )
        let verifier = StubArtifactVerifier()
        verifier.rejectedURLs = [update.artifactURL]
        let selector = RollbackSafeModelSelector(
            activeModel: old,
            verifier: verifier,
            capabilities: DeclaredModelCapabilities(identifiers: ["ane-v1"])
        )

        XCTAssertThrowsError(try selector.activate(update))
        XCTAssertEqual(selector.activeModel, old)
        XCTAssertNil(selector.rollbackModel)

        verifier.rejectedURLs = []
        try selector.activate(update)
        XCTAssertEqual(selector.activeModel, update)
        XCTAssertEqual(selector.rollbackModel, old)

        XCTAssertEqual(try selector.rollback(), old)
        XCTAssertEqual(selector.activeModel, old)
        XCTAssertEqual(selector.rollbackModel, update)
    }

    private func stubManifest(version: String, hashCharacter: Character) throws -> ModelManifest {
        try ModelManifest(
            modelID: "command-model",
            modelVersion: version,
            sha256: String(repeating: String(hashCharacter), count: 64),
            signature: Data([1]),
            sizeBytes: 1,
            minimumCapability: "ane-v1"
        )
    }

    private func writeTemporaryArtifact(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-model-\(UUID().uuidString).bin")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private final class StubArtifactVerifier: ModelArtifactVerifying {
    var rejectedURLs: Set<URL> = []

    func verifyArtifact(at url: URL, against manifest: ModelManifest) throws {
        if rejectedURLs.contains(url) {
            throw ModelArtifactVerificationError.hashMismatch
        }
    }
}
