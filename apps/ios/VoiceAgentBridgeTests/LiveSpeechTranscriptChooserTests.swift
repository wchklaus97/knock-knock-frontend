import XCTest
@testable import VoiceAgentBridge

final class LiveSpeechTranscriptChooserTests: XCTestCase {
    func testChineseLaneWinsOverEnglishGarbage() {
        XCTAssertEqual(
            LiveSpeechTranscriptChooser.choose(
                primary: "weather",
                companion: "今天天气怎么样"
            ),
            "今天天气怎么样"
        )
    }

    func testEnglishLaneWinsOverShortChineseGarbage() {
        XCTAssertEqual(
            LiveSpeechTranscriptChooser.choose(
                primary: "what is the weather today",
                companion: "什么"
            ),
            "what is the weather today"
        )
    }

    func testMixedChineseEnglishBeatsMonolingual() {
        XCTAssertEqual(
            LiveSpeechTranscriptChooser.choose(
                primary: "send John",
                companion: "发消息给 John 说你好"
            ),
            "发消息给 John 说你好"
        )
    }

    func testEmptyCompanionKeepsPrimary() {
        XCTAssertEqual(
            LiveSpeechTranscriptChooser.choose(primary: "Help with APNs", companion: "  "),
            "Help with APNs"
        )
    }

    func testEmptyPrimaryUsesCompanion() {
        XCTAssertEqual(
            LiveSpeechTranscriptChooser.choose(primary: "", companion: "问 Klaus 今天怎么样"),
            "问 Klaus 今天怎么样"
        )
    }
}

final class LiveSpeechLocalePairTests: XCTestCase {
    func testEnglishHongKongPairsWithChinese() {
        XCTAssertEqual(
            OnDeviceSpeechRecognizerFactory.companionIdentifiers(
                for: Locale(identifier: "en-HK")
            ),
            ["zh-HK", "yue-HK", "zh-CN", "zh-TW"]
        )
    }

    func testMandarinPairsWithEnglish() {
        XCTAssertEqual(
            OnDeviceSpeechRecognizerFactory.companionIdentifiers(
                for: Locale(identifier: "zh-Hans-HK")
            ),
            ["en-HK", "en-US", "en-GB"]
        )
    }

    func testCantonesePairsWithEnglish() {
        XCTAssertEqual(
            OnDeviceSpeechRecognizerFactory.companionIdentifiers(
                for: Locale(identifier: "yue-Hant-HK")
            ),
            ["en-HK", "en-US", "en-GB"]
        )
    }

    func testHongKongEnglishLiveLocaleUsesChineseDictation() {
        XCTAssertEqual(
            OnDeviceSpeechRecognizerFactory.preferredLiveLocale(
                from: Locale(identifier: "en-HK")
            ).identifier,
            "zh-HK"
        )
        XCTAssertEqual(
            OnDeviceSpeechRecognizerFactory.preferredLiveLocale(
                from: Locale(identifier: "zh-Hans-HK")
            ).identifier,
            "zh-Hans-HK"
        )
    }
}

final class MixedLanguageVoiceRoutingTests: XCTestCase {
    func testChineseAskStaysOffTheLocalShortcutPath() throws {
        XCTAssertFalse(
            LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: "今天天气怎么样")
        )
        XCTAssertNil(try LocalVoiceUtterancePreflight.intentHint(for: "今天天气怎么样"))
        XCTAssertFalse(
            LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: "问 Klaus 今天怎么样")
        )
        XCTAssertNil(try LocalVoiceUtterancePreflight.intentHint(for: "问 Klaus 今天怎么样"))
        XCTAssertFalse(
            LocalVoiceUtterancePreflight.prefersLocalCommandPath(
                for: "帮我 send John a message saying hello"
            )
        )
        XCTAssertFalse(
            LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: "明天 remind me to call John")
        )
    }

    func testChineseSendShortcutStillStaysOnThePhone() {
        XCTAssertTrue(
            LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: "发消息给 John")
        )
    }
}
