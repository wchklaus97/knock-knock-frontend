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
        let digestHex = hex(digest)
        let signature = try privateKey.signature(for: ModelManifest.signaturePayload(
            schemaVersion: 1,
            modelID: "gemma-command",
            modelVersion: "1.2.0",
            sha256: digestHex,
            sizeBytes: UInt64(artifact.count),
            minimumCapability: "ane-v1"
        ))
        let manifestJSON = """
        {
          "schema_version": 1,
          "model_id": "gemma-command",
          "model_version": "1.2.0",
          "sha256": "\(digestHex)",
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
        let digestHex = hex(digest)
        let wrongSignature = try wrongKey.signature(for: ModelManifest.signaturePayload(
            schemaVersion: 1,
            modelID: "whisper-small",
            modelVersion: "1.0.0",
            sha256: digestHex,
            sizeBytes: UInt64(original.count),
            minimumCapability: "cpu-v1"
        ))
        let manifest = try ModelManifest(
            modelID: "whisper-small",
            modelVersion: "1.0.0",
            sha256: digestHex,
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

    func testSignaturePayloadIsDeterministicAndRejectsEveryMetadataMutation() throws {
        let payload = ModelManifest.signaturePayload(
            schemaVersion: 1,
            modelID: "gemma-command",
            modelVersion: "1.2.3-rc.1+build.7",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 123_456,
            minimumCapability: "ane-v1"
        )
        XCTAssertEqual(String(data: payload, encoding: .utf8), """
        com.knockknock.voice-model-manifest.ed25519.v1
        schema_version=1
        model_id=gemma-command
        model_version=1.2.3-rc.1+build.7
        sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        size_bytes=123456
        minimum_capability=ane-v1

        """)

        let signingKey = Curve25519.Signing.PrivateKey()
        let signature = try signingKey.signature(for: payload)
        let mutations = [
            ModelManifest.signaturePayload(
                schemaVersion: 2,
                modelID: "gemma-command",
                modelVersion: "1.2.3-rc.1+build.7",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 123_456,
                minimumCapability: "ane-v1"
            ),
            ModelManifest.signaturePayload(
                schemaVersion: 1,
                modelID: "gemma-command-v2",
                modelVersion: "1.2.3-rc.1+build.7",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 123_456,
                minimumCapability: "ane-v1"
            ),
            ModelManifest.signaturePayload(
                schemaVersion: 1,
                modelID: "gemma-command",
                modelVersion: "1.2.4",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 123_456,
                minimumCapability: "ane-v1"
            ),
            ModelManifest.signaturePayload(
                schemaVersion: 1,
                modelID: "gemma-command",
                modelVersion: "1.2.3-rc.1+build.7",
                sha256: String(repeating: "b", count: 64),
                sizeBytes: 123_456,
                minimumCapability: "ane-v1"
            ),
            ModelManifest.signaturePayload(
                schemaVersion: 1,
                modelID: "gemma-command",
                modelVersion: "1.2.3-rc.1+build.7",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 123_457,
                minimumCapability: "ane-v1"
            ),
            ModelManifest.signaturePayload(
                schemaVersion: 1,
                modelID: "gemma-command",
                modelVersion: "1.2.3-rc.1+build.7",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 123_456,
                minimumCapability: "gpu-v1"
            ),
        ]
        for mutation in mutations {
            XCTAssertFalse(signingKey.publicKey.isValidSignature(signature, for: mutation))
        }
    }

    func testArtifactVerifierRejectsSignedMetadataSubstitution() throws {
        let artifact = Data("metadata-bound-model".utf8)
        let artifactURL = try writeTemporaryArtifact(artifact)
        defer { try? FileManager.default.removeItem(at: artifactURL) }
        let digest = Data(SHA256.hash(data: artifact))
        let digestHex = hex(digest)
        let signingKey = Curve25519.Signing.PrivateKey()
        let signature = try signingKey.signature(for: ModelManifest.signaturePayload(
            schemaVersion: 1,
            modelID: "gemma-command",
            modelVersion: "1.2.3",
            sha256: digestHex,
            sizeBytes: UInt64(artifact.count),
            minimumCapability: "cpu-v1"
        ))
        let verifier = try Ed25519ModelArtifactVerifier(
            publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation
        )
        let substitutions = [
            try ModelManifest(
                modelID: "gemma-command-v2",
                modelVersion: "1.2.3",
                sha256: digestHex,
                signature: signature,
                sizeBytes: UInt64(artifact.count),
                minimumCapability: "cpu-v1"
            ),
            try ModelManifest(
                modelID: "gemma-command",
                modelVersion: "1.2.4",
                sha256: digestHex,
                signature: signature,
                sizeBytes: UInt64(artifact.count),
                minimumCapability: "cpu-v1"
            ),
            try ModelManifest(
                modelID: "gemma-command",
                modelVersion: "1.2.3",
                sha256: digestHex,
                signature: signature,
                sizeBytes: UInt64(artifact.count),
                minimumCapability: "gpu-v1"
            ),
        ]

        for manifest in substitutions {
            XCTAssertThrowsError(
                try verifier.verifyArtifact(at: artifactURL, against: manifest)
            ) { error in
                XCTAssertEqual(error as? ModelArtifactVerificationError, .signatureMismatch)
            }
        }
    }

    func testManifestUsesSemVerPrecedenceAndRejectsMalformedVersions() throws {
        let accepted = [
            "0.0.0",
            "1.2.3-alpha",
            "1.2.3-alpha.1",
            "1.2.3-rc.1+build.7",
            "1.2.3+build.7",
        ]
        for version in accepted {
            XCTAssertNoThrow(try stubManifest(version: version, hashCharacter: "a"), version)
        }

        let rejected = [
            "1.2",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.2.3-",
            "1.2.3-alpha..1",
            "1.2.3-01",
            "1.2.3+",
            "1.2.3+build+again",
        ]
        for version in rejected {
            XCTAssertThrowsError(try stubManifest(version: version, hashCharacter: "a"), version)
        }

        let verifier = StubArtifactVerifier()
        let alpha2 = InstalledModel(
            manifest: try stubManifest(version: "1.0.0-alpha.2", hashCharacter: "a"),
            artifactURL: URL(fileURLWithPath: "/models/alpha-2.bin")
        )
        let alpha10 = InstalledModel(
            manifest: try stubManifest(version: "1.0.0-alpha.10", hashCharacter: "b"),
            artifactURL: URL(fileURLWithPath: "/models/alpha-10.bin")
        )
        let release = InstalledModel(
            manifest: try stubManifest(version: "1.0.0", hashCharacter: "c"),
            artifactURL: URL(fileURLWithPath: "/models/release.bin")
        )
        let olderPrerelease = InstalledModel(
            manifest: try stubManifest(version: "1.0.0-rc.9", hashCharacter: "d"),
            artifactURL: URL(fileURLWithPath: "/models/rc.bin")
        )
        let selector = RollbackSafeModelSelector(
            activeModel: alpha2,
            verifier: verifier,
            capabilities: DeclaredModelCapabilities(identifiers: ["ane-v1"])
        )
        XCTAssertNoThrow(try selector.activate(alpha10))
        XCTAssertNoThrow(try selector.activate(release))
        XCTAssertThrowsError(try selector.activate(olderPrerelease)) { error in
            XCTAssertEqual(error as? ModelSelectionError, .downgradeRejected)
        }
    }

    func testManifestEnforcesEd25519SignatureAndAbsoluteArtifactSize() {
        XCTAssertThrowsError(try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: String(repeating: "0", count: 64),
            signature: Data(repeating: 1, count: 63),
            sizeBytes: 1,
            minimumCapability: "cpu-v1"
        ))
        XCTAssertNoThrow(try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: String(repeating: "0", count: 64),
            signature: Data(repeating: 1, count: 64),
            sizeBytes: ModelManifest.maximumArtifactSizeBytes,
            minimumCapability: "cpu-v1"
        ))
        XCTAssertThrowsError(try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: String(repeating: "0", count: 64),
            signature: Data(repeating: 1, count: 64),
            sizeBytes: ModelManifest.maximumArtifactSizeBytes + 1,
            minimumCapability: "cpu-v1"
        ))
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
            signature: Data(repeating: 1, count: 64),
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

final class LiteRTConversationCommandRunnerTests: XCTestCase {
    func testEachCommandCreatesThenDeletesItsOwnConversationInOrder() throws {
        var events: [String] = []
        var nextConversation = 0
        let runner = LiteRTConversationCommandRunner<Int, Int>(
            makeConversation: {
                nextConversation += 1
                events.append("create:\(nextConversation)")
                return nextConversation
            },
            deleteConversation: { events.append("delete-conversation:\($0)") },
            sendMessage: { conversation, message in
                events.append("send:\(conversation):\(message)")
                return conversation
            },
            responseString: { response in
                events.append("read-response:\(response)")
                return "response-\(response)"
            },
            deleteResponse: { events.append("delete-response:\($0)") }
        )

        XCTAssertEqual(try runner.run(messageJSON: "first"), "response-1")
        XCTAssertEqual(try runner.run(messageJSON: "second"), "response-2")
        XCTAssertEqual(events, [
            "create:1",
            "send:1:first",
            "read-response:1",
            "delete-response:1",
            "delete-conversation:1",
            "create:2",
            "send:2:second",
            "read-response:2",
            "delete-response:2",
            "delete-conversation:2",
        ])
    }

    func testConversationAndResponseAreDeletedOnFailurePaths() {
        var sendFailureEvents: [String] = []
        let sendFailure = LiteRTConversationCommandRunner<Int, Int>(
            makeConversation: {
                sendFailureEvents.append("create")
                return 1
            },
            deleteConversation: { _ in sendFailureEvents.append("delete-conversation") },
            sendMessage: { _, _ in
                sendFailureEvents.append("send")
                return nil
            },
            responseString: { _ in XCTFail("No response should be read"); return nil },
            deleteResponse: { _ in XCTFail("No response should be deleted") }
        )
        XCTAssertThrowsError(try sendFailure.run(messageJSON: "request"))
        XCTAssertEqual(sendFailureEvents, ["create", "send", "delete-conversation"])

        var decodeFailureEvents: [String] = []
        let decodeFailure = LiteRTConversationCommandRunner<Int, Int>(
            makeConversation: {
                decodeFailureEvents.append("create")
                return 1
            },
            deleteConversation: { _ in decodeFailureEvents.append("delete-conversation") },
            sendMessage: { _, _ in
                decodeFailureEvents.append("send")
                return 2
            },
            responseString: { _ in
                decodeFailureEvents.append("read-response")
                return nil
            },
            deleteResponse: { _ in decodeFailureEvents.append("delete-response") }
        )
        XCTAssertThrowsError(try decodeFailure.run(messageJSON: "request"))
        XCTAssertEqual(decodeFailureEvents, [
            "create",
            "send",
            "read-response",
            "delete-response",
            "delete-conversation",
        ])
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
