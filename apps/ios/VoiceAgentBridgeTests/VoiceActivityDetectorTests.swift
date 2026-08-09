import AVFoundation
import XCTest
@testable import VoiceAgentBridge

final class VoiceActivityDetectorTests: XCTestCase {
    func testSilenceBeforeSpeechDoesNotStopCapture() {
        var vad = makeVAD()

        for _ in 0..<20 {
            XCTAssertEqual(vad.process(levelDB: -70, duration: 0.1), .none)
        }
        XCTAssertFalse(vad.hasDetectedSpeech)
    }

    func testSustainedSpeechThenSilenceStops() {
        var vad = makeVAD()

        XCTAssertEqual(vad.process(levelDB: -20, duration: 0.1), .none)
        XCTAssertEqual(vad.process(levelDB: -20, duration: 0.1), .speechStarted)
        XCTAssertEqual(vad.process(levelDB: -60, duration: 0.2), .none)
        XCTAssertEqual(vad.process(levelDB: -60, duration: 0.3), .silenceLimitReached)
    }

    func testBriefNoiseDoesNotCountAsSpeech() {
        var vad = makeVAD()

        XCTAssertEqual(vad.process(levelDB: -10, duration: 0.1), .none)
        XCTAssertEqual(vad.process(levelDB: -70, duration: 0.1), .none)
        XCTAssertEqual(vad.process(levelDB: -10, duration: 0.1), .none)
        XCTAssertFalse(vad.hasDetectedSpeech)
    }

    func testPCMLevelUsesRMSWithoutRetainingSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4 {
            samples[index] = 0.5
        }

        XCTAssertEqual(VoiceActivityDetector.levelDB(for: buffer), -6.0206, accuracy: 0.001)
    }

    private func makeVAD() -> VoiceActivityDetector {
        VoiceActivityDetector(configuration: .init(
            speechThresholdDB: -40,
            minimumSpeechDuration: 0.2,
            silenceDurationToStop: 0.5
        ))
    }
}
