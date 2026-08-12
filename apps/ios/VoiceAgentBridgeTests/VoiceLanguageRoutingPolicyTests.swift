import Foundation
import XCTest
@testable import VoiceAgentBridge

final class VoiceLanguageRoutingPolicyTests: XCTestCase {
    func testLocaleClassificationIsExplicitAndRejectsUnsupportedLanguages() {
        XCTAssertEqual(VoiceLanguage(locale: Locale(identifier: "en_HK")), .englishHongKong)
        XCTAssertEqual(VoiceLanguage(locale: Locale(identifier: "zh-Hans-CN")), .mandarinSimplified)
        XCTAssertEqual(VoiceLanguage(locale: Locale(identifier: "yue-Hant-HK")), .cantoneseTraditional)
        XCTAssertEqual(VoiceLanguage(locale: Locale(identifier: "zh-HK")), .cantoneseTraditional)
        XCTAssertNil(VoiceLanguage(locale: Locale(identifier: "fr-FR")))
    }

    func testIOS26RoutesCantoneseToAppleAndMandarinToReadySenseVoice() {
        let cantonese = VoiceLanguageRoutingPolicy.route(
            language: .cantoneseTraditional,
            supportsSpeechAnalyzer: true,
            senseVoiceReady: true
        )
        XCTAssertEqual(cantonese.backend, .appleSpeechAnalyzer)
        XCTAssertEqual(cantonese.fallbackBackend, .senseVoice)
        XCTAssertFalse(cantonese.requiresStrictClarification)

        let mandarin = VoiceLanguageRoutingPolicy.route(
            language: .mandarinSimplified,
            supportsSpeechAnalyzer: true,
            senseVoiceReady: true
        )
        XCTAssertEqual(mandarin.backend, .senseVoice)
        XCTAssertEqual(mandarin.fallbackBackend, .appleSpeechAnalyzer)
        XCTAssertFalse(mandarin.requiresStrictClarification)
    }

    func testMissingQualifiedBackendFailsSafe() {
        let mandarin = VoiceLanguageRoutingPolicy.route(
            language: .mandarinSimplified,
            supportsSpeechAnalyzer: true,
            senseVoiceReady: false
        )
        XCTAssertEqual(mandarin.backend, .appleSpeechAnalyzer)
        XCTAssertTrue(mandarin.requiresStrictClarification)

        let english = VoiceLanguageRoutingPolicy.route(
            language: .englishHongKong,
            supportsSpeechAnalyzer: true,
            senseVoiceReady: false
        )
        XCTAssertEqual(english.backend, .appleSpeechAnalyzer)
        XCTAssertTrue(english.requiresStrictClarification)
    }

    func testCantoneseTranscriptIsConvertedToTraditionalWithoutChangingLatinEntities() {
        XCTAssertEqual(
            VoiceTranscriptNormalizer.normalize("发送消息给 John", for: .cantoneseTraditional),
            "發送消息給 John"
        )
        XCTAssertEqual(
            VoiceTranscriptNormalizer.normalize("发送消息给 John", for: .mandarinSimplified),
            "发送消息给 John"
        )
    }
}
