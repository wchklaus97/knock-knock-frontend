import AVFoundation
import XCTest
@testable import VoiceAgentBridge

final class VoiceActivityDetectorTests: XCTestCase {
    @MainActor
    func testCaptureRefusesToStartWhenApplicationIsAlreadyInactive() {
        let capture = PushToTalkVoiceCapture(applicationIsActive: { false })

        XCTAssertThrowsError(try capture.start(
            onTranscript: { _ in XCTFail("Inactive capture must not emit a transcript") },
            onStop: { _ in XCTFail("Inactive capture must not stop normally") },
            onAbort: { _ in XCTFail("Inactive capture must not reach an active lifecycle") },
            onError: { _ in XCTFail("Inactive capture must fail synchronously") }
        )) { error in
            XCTAssertEqual(error as? PushToTalkVoiceCapture.CaptureError, .applicationNotActive)
        }
        XCTAssertEqual(capture.state, .idle)
    }

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

    func testNoSpeechTimeoutStopsWithoutEverDetectingSpeech() {
        var vad = VoiceActivityDetector(configuration: .init(
            speechThresholdDB: -40,
            minimumSpeechDuration: 0.2,
            silenceDurationToStop: 0.5,
            noSpeechTimeout: 0.5,
            maximumCaptureDuration: 2
        ))

        XCTAssertEqual(vad.process(levelDB: -70, duration: 0.25), .none)
        XCTAssertEqual(vad.process(levelDB: -70, duration: 0.25), .noSpeechTimeoutReached)
        XCTAssertEqual(vad.process(levelDB: -70, duration: 0.25), .none)
        XCTAssertFalse(vad.hasDetectedSpeech)
    }

    func testMaximumDurationStopsEvenDuringSpeech() {
        var vad = VoiceActivityDetector(configuration: .init(
            speechThresholdDB: -40,
            minimumSpeechDuration: 0.1,
            silenceDurationToStop: 0.5,
            noSpeechTimeout: 1,
            maximumCaptureDuration: 0.6
        ))

        XCTAssertEqual(vad.process(levelDB: -20, duration: 0.1), .speechStarted)
        XCTAssertEqual(vad.process(levelDB: -20, duration: 0.4), .none)
        XCTAssertEqual(vad.process(levelDB: -20, duration: 0.11), .maximumDurationReached)
        XCTAssertEqual(vad.process(levelDB: -20, duration: 0.1), .none)
    }

    func testSpeechAtNoSpeechBoundaryWinsOverTimeout() {
        var vad = VoiceActivityDetector(configuration: .init(
            speechThresholdDB: -40,
            minimumSpeechDuration: 0.2,
            silenceDurationToStop: 0.5,
            noSpeechTimeout: 0.5,
            maximumCaptureDuration: 2
        ))

        XCTAssertEqual(vad.process(levelDB: -70, duration: 0.3), .none)
        XCTAssertEqual(vad.process(levelDB: -20, duration: 0.2), .speechStarted)
        XCTAssertTrue(vad.hasDetectedSpeech)
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
            silenceDurationToStop: 0.5,
            noSpeechTimeout: 3,
            maximumCaptureDuration: 10
        ))
    }
}
