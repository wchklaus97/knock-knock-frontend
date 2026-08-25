import Foundation
import XCTest
@testable import VoiceAgentBridge

/// Pins the signed-Gemma generateExclusively preflight gate without loading a
/// LiteRT / Gemma model: nil intent is Ask (`unsupportedIntent`), the four
/// local shortcuts pass through, and generateExclusively must not call
/// LocalCommandIntentClassifier.
final class SignedGemmaGenerateExclusivelyTests: XCTestCase {
    func testNilPreflightIntentThrowsUnsupportedIntentForAsk() {
        XCTAssertThrowsError(
            try SignedGemmaGenerateExclusively.requireKnownIntent(nil)
        ) { error in
            XCTAssertEqual(
                error as? LocalCommandEnvelopeCanonicalizerError,
                .clarificationRequired(.unsupportedIntent)
            )
        }
    }

    func testFourShortcutIntentsPassThrough() throws {
        for intent in [
            "search_history",
            "create_reminder",
            "create_draft",
            "send_message",
        ] {
            XCTAssertEqual(
                try SignedGemmaGenerateExclusively.requireKnownIntent(intent),
                intent,
                intent
            )
        }
    }

    func testGenerateExclusivelyUsesTheSeamAndDoesNotCallIntentClassifier() throws {
        let source = try generateExclusivelySource()
        XCTAssertTrue(
            source.contains("SignedGemmaGenerateExclusively.requireKnownIntent"),
            "generateExclusively must call the nil-intent seam so Ask does not need a model"
        )
        XCTAssertFalse(
            source.contains("LocalCommandIntentClassifier"),
            "generateExclusively must not run the old 分类 classifier"
        )
    }

    private func generateExclusivelySource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoiceAgentBridge/Voice/LocalVoiceAdapters.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let startMarker = "private func generateExclusively("
        let endMarker = "\n    private static func startStream("
        guard let start = source.range(of: startMarker),
              let end = source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
              )
        else {
            struct MissingGenerateExclusively: Error {}
            throw MissingGenerateExclusively()
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
