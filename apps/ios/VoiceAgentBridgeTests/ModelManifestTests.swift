import CryptoKit
import XCTest
@testable import VoiceAgentBridge

final class ModelManifestTests: XCTestCase {
    func testLiteRTModelOutputParserAcceptsOnlyOneCompleteJSONObject() throws {
        let accepted = try LiteRTModelOutputParser.extractJSONObject(
            from: "  \n{\"intent\":\"search_history\",\"args\":{}}\t "
        )
        XCTAssertEqual(
            String(data: accepted, encoding: .utf8),
            "{\"intent\":\"search_history\",\"args\":{}}"
        )

        let rejected = [
            "Here is the command: {\"intent\":\"search_history\"}",
            "```json\n{\"intent\":\"search_history\"}\n```",
            "[{\"intent\":\"search_history\"}]",
            "{\"intent\":\"search_history\"} trailing",
            "{\"intent\":\"search_history\"}{\"intent\":\"create_reminder\"}",
            "{\"intent\":\"search_history\",\"intent\":\"create_reminder\"}",
        ]
        for output in rejected {
            XCTAssertThrowsError(try LiteRTModelOutputParser.extractJSONObject(from: output)) {
                XCTAssertEqual($0 as? LocalVoiceAdapterError, .invalidModelOutput)
            }
        }
    }

    func testVoiceModelRefreshAlwaysFetchesWhileOrdinaryPrepareUsesInstalledModel() {
        XCTAssertTrue(AppStore.shouldFetchVoiceModel(
            forceRefresh: false,
            activeModelAvailable: false
        ))
        XCTAssertFalse(AppStore.shouldFetchVoiceModel(
            forceRefresh: false,
            activeModelAvailable: true
        ))
        XCTAssertTrue(AppStore.shouldFetchVoiceModel(
            forceRefresh: true,
            activeModelAvailable: true
        ))
    }

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

    func testCancelDuringStreamingInvokesNativeCancelAndDeletesConversationExactlyOnce() async {
        let callbackReady = expectation(description: "stream callback installed")
        let events = LockedEvents()
        let callbackBox = StreamCallbackBox()
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: {
                events.append("create")
                return 7
            },
            deleteConversation: { conversation in
                events.append("delete:\(conversation)")
            },
            startStream: { conversation, message, callback in
                events.append("start:\(conversation):\(message)")
                callbackBox.callback = callback
                callbackReady.fulfill()
                return 0
            },
            cancelConversation: { conversation in
                events.append("cancel:\(conversation)")
            }
        )

        let task = Task {
            try await runner.run(messageJSON: "request")
        }
        await fulfillment(of: [callbackReady], timeout: 1)
        task.cancel()
        callbackBox.callback?(nil, true, nil).finish()

        do {
            _ = try await task.value
            XCTFail("Cancellation should not return a partial model response")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(events.values, [
            "create",
            "start:7:request",
            "cancel:7",
            "delete:7",
        ])
    }

    func testStreamingConcatenatesChunksAndDeletesConversationAfterFinalCallback() async throws {
        let events = LockedEvents()
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: {
                events.append("create")
                return 11
            },
            deleteConversation: { conversation in
                events.append("delete:\(conversation)")
            },
            startStream: { conversation, message, callback in
                events.append("start:\(conversation):\(message)")
                callback("{\"intent\":", false, nil).finish()
                callback("\"search_history\"}", true, nil).finish()
                return 0
            },
            cancelConversation: { _ in
                XCTFail("A successful stream must not be cancelled")
            }
        )

        let response = try await runner.run(messageJSON: "request")

        XCTAssertEqual(response, #"{"intent":"search_history"}"#)
        XCTAssertEqual(events.values, [
            "create",
            "start:11:request",
            "delete:11",
        ])
    }

    func testStreamingStartFailureDeletesConversationWithoutCancelling() async {
        let events = LockedEvents()
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: {
                events.append("create")
                return 13
            },
            deleteConversation: { conversation in
                events.append("delete:\(conversation)")
            },
            startStream: { conversation, _, _ in
                events.append("start:\(conversation)")
                return 1
            },
            cancelConversation: { _ in
                XCTFail("A stream that never started must not be cancelled")
            }
        )

        do {
            _ = try await runner.run(messageJSON: "request")
            XCTFail("A nonzero native start status must fail")
        } catch let error as LocalVoiceAdapterError {
            XCTAssertEqual(error, .gemmaRuntimeGenerationFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(events.values, [
            "create",
            "start:13",
            "delete:13",
        ])
    }

    func testCancelFinalRaceDoesNotDeleteWhileNativeCancelIsInFlight() async {
        let callbackReady = expectation(description: "stream callback installed")
        let conversationDeleted = expectation(description: "conversation deleted")
        let callbackExited = DispatchSemaphore(value: 0)
        let callbackBox = StreamCallbackBox()
        let events = LockedEvents()
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: {
                events.append("create")
                return 17
            },
            deleteConversation: { conversation in
                events.append("delete:\(conversation)")
                conversationDeleted.fulfill()
            },
            startStream: { conversation, _, callback in
                events.append("start:\(conversation)")
                callbackBox.callback = callback
                callbackReady.fulfill()
                return 0
            },
            cancelConversation: { conversation in
                events.append("cancel-enter:\(conversation)")
                DispatchQueue.global().async {
                    events.append("callback-enter")
                    callbackBox.callback?(nil, true, nil).finish()
                    events.append("callback-exit")
                    callbackExited.signal()
                }
                _ = callbackExited.wait(timeout: .now() + 0.25)
                events.append("cancel-exit:\(conversation)")
            }
        )

        let task = Task.detached { try await runner.run(messageJSON: "request") }
        await fulfillment(of: [callbackReady], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation should win the terminal callback race")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [conversationDeleted], timeout: 1)

        let values = events.values
        XCTAssertEqual(values.filter { $0 == "delete:17" }.count, 1)
        let cancelEnterIndex = values.firstIndex(of: "cancel-enter:17")
        let callbackEnterIndex = values.firstIndex(of: "callback-enter")
        let cancelExitIndex = values.firstIndex(of: "cancel-exit:17")
        let deleteIndex = values.firstIndex(of: "delete:17")
        XCTAssertNotNil(cancelEnterIndex)
        XCTAssertNotNil(callbackEnterIndex)
        XCTAssertNotNil(cancelExitIndex)
        XCTAssertNotNil(deleteIndex)
        if let cancelEnterIndex, let callbackEnterIndex, let cancelExitIndex, let deleteIndex {
            XCTAssertLessThan(cancelEnterIndex, callbackEnterIndex)
            XCTAssertLessThan(callbackEnterIndex, cancelExitIndex)
            XCTAssertLessThan(cancelExitIndex, deleteIndex)
        }
    }

    func testTerminalCallbackDoesNotDeleteConversationUntilCallbackExit() async throws {
        let callbackReady = expectation(description: "stream callback installed")
        let conversationDeleted = expectation(description: "conversation deleted")
        let callbackBox = StreamCallbackBox()
        let events = LockedEvents()
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: {
                events.append("create")
                return 19
            },
            deleteConversation: { conversation in
                events.append("delete:\(conversation)")
                conversationDeleted.fulfill()
            },
            startStream: { _, _, callback in
                callbackBox.callback = callback
                callbackReady.fulfill()
                return 0
            },
            cancelConversation: { _ in
                XCTFail("A successful stream must not be cancelled")
            }
        )

        let task = Task { try await runner.run(messageJSON: "request") }
        await fulfillment(of: [callbackReady], timeout: 1)
        let callbackExit = try XCTUnwrap(callbackBox.callback?("complete", true, nil))
        XCTAssertFalse(events.values.contains("delete:19"))

        callbackExit.finish()
        let output = try await task.value
        XCTAssertEqual(output, "complete")
        await fulfillment(of: [conversationDeleted], timeout: 1)
        XCTAssertEqual(events.values, ["create", "delete:19"])
    }

    func testTerminalCleanupRunsOffCallbackAndResumesOnlyAfterDeletion() async throws {
        let callbackReady = expectation(description: "stream callback installed")
        let cleanupStarted = expectation(description: "cleanup started")
        let conversationDeleted = expectation(description: "conversation deleted")
        let callbackReturned = DispatchSemaphore(value: 0)
        let cleanupQueue = DispatchQueue(label: "LiteRTConversationCommandRunnerTests.cleanup")
        let cleanupQueueKey = DispatchSpecificKey<Bool>()
        cleanupQueue.setSpecific(key: cleanupQueueKey, value: true)
        let callbackBox = StreamCallbackBox()
        let events = LockedEvents()
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: {
                events.append("create")
                return 21
            },
            deleteConversation: { conversation in
                XCTAssertEqual(DispatchQueue.getSpecific(key: cleanupQueueKey), true)
                events.append("cleanup-enter")
                cleanupStarted.fulfill()
                _ = callbackReturned.wait(timeout: .now() + 2)
                events.append("delete:\(conversation)")
                conversationDeleted.fulfill()
            },
            startStream: { _, _, callback in
                callbackBox.callback = callback
                callbackReady.fulfill()
                return 0
            },
            cancelConversation: { _ in
                XCTFail("A successful stream must not be cancelled")
            },
            scheduleCleanup: { action in
                cleanupQueue.async(execute: action)
            }
        )

        let task = Task {
            let output = try await runner.run(messageJSON: "request")
            events.append("runner-complete")
            return output
        }
        await fulfillment(of: [callbackReady], timeout: 1)
        let callback = try XCTUnwrap(callbackBox.callback)
        let callbackExit = callback("complete", true, nil)

        finishLiteRTStreamCallback(callbackExit) {
            events.append("release-context")
        }
        events.append("bridge-return")
        await fulfillment(of: [cleanupStarted], timeout: 1)

        XCTAssertFalse(events.values.contains("delete:21"))
        XCTAssertFalse(events.values.contains("runner-complete"))
        events.append("native-callback-returned")
        callbackReturned.signal()

        let output = try await task.value
        XCTAssertEqual(output, "complete")
        await fulfillment(of: [conversationDeleted], timeout: 1)
        let values = events.values
        XCTAssertEqual(values.filter { $0 == "delete:21" }.count, 1)
        XCTAssertLessThan(
            try XCTUnwrap(values.firstIndex(of: "release-context")),
            try XCTUnwrap(values.firstIndex(of: "cleanup-enter"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(values.firstIndex(of: "native-callback-returned")),
            try XCTUnwrap(values.firstIndex(of: "delete:21"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(values.firstIndex(of: "delete:21")),
            try XCTUnwrap(values.firstIndex(of: "runner-complete"))
        )
    }

    func testExclusiveGenerationGateSerializesWaiters() async {
        let gate = LiteRTExclusiveGenerationGate()
        let secondAcquired = expectation(description: "second generation acquired permit")
        let events = LockedEvents()

        await gate.acquire()
        let waiter = Task {
            await gate.acquire()
            events.append("second-acquired")
            secondAcquired.fulfill()
            await gate.release()
        }

        var waitingCount = await gate.waitingCount
        for _ in 0..<100 where waitingCount == 0 {
            await Task.yield()
            waitingCount = await gate.waitingCount
        }
        XCTAssertEqual(waitingCount, 1)
        XCTAssertFalse(events.values.contains("second-acquired"))

        await gate.release()
        await fulfillment(of: [secondAcquired], timeout: 1)
        await waiter.value
        XCTAssertEqual(events.values, ["second-acquired"])
    }

    func testExclusiveGenerationGateCancelledWaiterHandsPermitToNextWaiter() async {
        let gate = LiteRTExclusiveGenerationGate()
        let cancelledWaiterReleased = expectation(description: "cancelled waiter released permit")
        let nextWaiterAcquired = expectation(description: "next waiter acquired permit")
        let events = LockedEvents()

        await gate.acquire()
        let cancelledWaiter = Task {
            await gate.acquire()
            events.append(Task.isCancelled ? "cancelled-waiter" : "unexpected-active-waiter")
            cancelledWaiterReleased.fulfill()
            await gate.release()
        }

        var waitingCount = await gate.waitingCount
        for _ in 0..<100 where waitingCount < 1 {
            await Task.yield()
            waitingCount = await gate.waitingCount
        }
        XCTAssertEqual(waitingCount, 1)
        cancelledWaiter.cancel()

        let nextWaiter = Task {
            await gate.acquire()
            events.append("next-waiter")
            nextWaiterAcquired.fulfill()
            await gate.release()
        }

        waitingCount = await gate.waitingCount
        for _ in 0..<100 where waitingCount < 2 {
            await Task.yield()
            waitingCount = await gate.waitingCount
        }
        XCTAssertEqual(waitingCount, 2)

        await gate.release()
        await fulfillment(of: [cancelledWaiterReleased, nextWaiterAcquired], timeout: 1)
        await cancelledWaiter.value
        await nextWaiter.value
        XCTAssertEqual(events.values, ["cancelled-waiter", "next-waiter"])
    }

    func testCancellationWhileStartStreamIsBlockedCancelsExactlyOnceAfterSuccessfulStart() async {
        let startEntered = expectation(description: "native start entered")
        let cancelCalled = expectation(description: "native cancel called")
        let conversationDeleted = expectation(description: "conversation deleted")
        let allowStartToReturn = DispatchSemaphore(value: 0)
        let callbackBox = StreamCallbackBox()
        let events = LockedEvents()
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: { 23 },
            deleteConversation: { conversation in
                events.append("delete:\(conversation)")
                conversationDeleted.fulfill()
            },
            startStream: { conversation, _, callback in
                events.append("start-enter:\(conversation)")
                callbackBox.callback = callback
                startEntered.fulfill()
                _ = allowStartToReturn.wait(timeout: .now() + 2)
                events.append("start-exit:\(conversation)")
                return 0
            },
            cancelConversation: { conversation in
                events.append("cancel:\(conversation)")
                cancelCalled.fulfill()
            }
        )

        let task = Task { try await runner.run(messageJSON: "request") }
        await fulfillment(of: [startEntered], timeout: 1)
        task.cancel()
        task.cancel()
        XCTAssertFalse(events.values.contains("cancel:23"))

        allowStartToReturn.signal()
        await fulfillment(of: [cancelCalled], timeout: 1)
        XCTAssertEqual(events.values.filter { $0 == "cancel:23" }.count, 1)
        callbackBox.callback?(nil, true, nil).finish()

        do {
            _ = try await task.value
            XCTFail("A cancelled task must not return model output")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [conversationDeleted], timeout: 1)
        XCTAssertEqual(events.values, [
            "start-enter:23",
            "start-exit:23",
            "cancel:23",
            "delete:23",
        ])
    }

    func testCancellationDuringFailedStartNeverCallsNativeCancel() async {
        let startEntered = expectation(description: "native start entered")
        let conversationDeleted = expectation(description: "conversation deleted")
        let allowStartToReturn = DispatchSemaphore(value: 0)
        let events = LockedEvents()
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: { 29 },
            deleteConversation: { conversation in
                events.append("delete:\(conversation)")
                conversationDeleted.fulfill()
            },
            startStream: { conversation, _, _ in
                events.append("start-enter:\(conversation)")
                startEntered.fulfill()
                _ = allowStartToReturn.wait(timeout: .now() + 2)
                events.append("start-failed:\(conversation)")
                return 1
            },
            cancelConversation: { conversation in
                events.append("unexpected-cancel:\(conversation)")
            }
        )

        let task = Task { try await runner.run(messageJSON: "request") }
        await fulfillment(of: [startEntered], timeout: 1)
        task.cancel()
        task.cancel()
        allowStartToReturn.signal()

        do {
            _ = try await task.value
            XCTFail("A cancelled failed-start task must not return output")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [conversationDeleted], timeout: 1)
        XCTAssertEqual(events.values, [
            "start-enter:29",
            "start-failed:29",
            "delete:29",
        ])
    }

    func testStreamingReconstructsLiteRTMessageJSONAndStrictEnvelope() async throws {
        let envelopeJSON = #"{"schema_version":1,"command_id":"cmd_stream_1","intent":"search_history","args":{"q":"你好 \"Klaus\""},"risk_level":"low","needs_confirmation":false,"idempotency_key":"idem_stream_1","confidence":0.96,"locale":"zh-Hans-HK","timezone":"Asia/Hong_Kong"}"#
        let split = try XCTUnwrap(envelopeJSON.range(of: #"\"Klaus\""#)?.lowerBound)
        let firstFragment = String(envelopeJSON[..<split])
        let secondFragment = String(envelopeJSON[split...])
        let firstMessage = try liteRTMessageJSON(content: firstFragment, asParts: true)
        let secondMessage = try liteRTMessageJSON(content: secondFragment, asParts: false)
        let runner = LiteRTStreamingConversationCommandRunner<Int>(
            makeConversation: { 31 },
            deleteConversation: { _ in },
            startStream: { _, _, callback in
                callback(
                    LiteRTModelOutputParser.responseText(from: firstMessage),
                    false,
                    nil
                ).finish()
                callback(
                    LiteRTModelOutputParser.responseText(from: secondMessage),
                    false,
                    nil
                ).finish()
                callback(nil, true, nil).finish()
                return 0
            },
            cancelConversation: { _ in
                XCTFail("A successful stream must not be cancelled")
            }
        )

        let output = try await runner.run(messageJSON: "request")
        let data = try LiteRTModelOutputParser.extractJSONObject(from: output)
        let envelope = try CommandEnvelope.decodeStrict(from: data)

        XCTAssertEqual(envelope.commandID, "cmd_stream_1")
        XCTAssertEqual(envelope.intent, "search_history")
        XCTAssertEqual(envelope.args["q"], .string("你好 \"Klaus\""))
    }

    private func liteRTMessageJSON(content: String, asParts: Bool) throws -> String {
        let object: [String: Any]
        if asParts {
            object = ["content": [["type": "text", "text": content]]]
        } else {
            object = ["content": content]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class StreamCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LiteRTStreamingConversationCommandRunner<Int>.StreamCallback?

    var callback: LiteRTStreamingConversationCommandRunner<Int>.StreamCallback? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
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
