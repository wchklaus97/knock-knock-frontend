import AVFoundation
import Foundation

/// A deliberately small, deterministic energy-based VAD for push-to-talk.
/// It never retains audio samples; callers provide one frame's level and duration.
struct VoiceActivityDetector {
    struct Configuration: Equatable {
        var speechThresholdDB: Float = -42
        var minimumSpeechDuration: TimeInterval = 0.12
        var silenceDurationToStop: TimeInterval = 0.8
        var noSpeechTimeout: TimeInterval = 4
        var maximumCaptureDuration: TimeInterval = 30

        init(
            speechThresholdDB: Float = -42,
            minimumSpeechDuration: TimeInterval = 0.12,
            silenceDurationToStop: TimeInterval = 0.8,
            noSpeechTimeout: TimeInterval = 4,
            maximumCaptureDuration: TimeInterval = 30
        ) {
            self.speechThresholdDB = speechThresholdDB
            self.minimumSpeechDuration = minimumSpeechDuration
            self.silenceDurationToStop = silenceDurationToStop
            self.noSpeechTimeout = noSpeechTimeout
            self.maximumCaptureDuration = maximumCaptureDuration
        }
    }

    enum Event: Equatable {
        case none
        case speechStarted
        case silenceLimitReached
        case noSpeechTimeoutReached
        case maximumDurationReached
    }

    private let configuration: Configuration
    private(set) var hasDetectedSpeech = false
    private var candidateSpeechDuration: TimeInterval = 0
    private var trailingSilenceDuration: TimeInterval = 0
    private var captureDuration: TimeInterval = 0
    private var isTerminal = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func reset() {
        hasDetectedSpeech = false
        candidateSpeechDuration = 0
        trailingSilenceDuration = 0
        captureDuration = 0
        isTerminal = false
    }

    mutating func process(levelDB: Float, duration: TimeInterval) -> Event {
        guard !isTerminal, duration > 0, duration.isFinite else { return .none }
        captureDuration += duration
        if captureDuration >= configuration.maximumCaptureDuration {
            isTerminal = true
            return .maximumDurationReached
        }

        let isSpeech = levelDB.isFinite && levelDB >= configuration.speechThresholdDB

        if !hasDetectedSpeech {
            candidateSpeechDuration = isSpeech ? candidateSpeechDuration + duration : 0
            if candidateSpeechDuration >= configuration.minimumSpeechDuration {
                hasDetectedSpeech = true
                trailingSilenceDuration = 0
                return .speechStarted
            }
            if captureDuration >= configuration.noSpeechTimeout {
                isTerminal = true
                return .noSpeechTimeoutReached
            }
            return .none
        }

        if isSpeech {
            trailingSilenceDuration = 0
            return .none
        }

        trailingSilenceDuration += duration
        if trailingSilenceDuration >= configuration.silenceDurationToStop {
            isTerminal = true
            return .silenceLimitReached
        }
        return .none
    }

    static func levelDB(for buffer: AVAudioPCMBuffer) -> Float {
        guard
            buffer.frameLength > 0,
            let channels = buffer.floatChannelData
        else {
            return -.infinity
        }

        let channelCount = max(1, Int(buffer.format.channelCount))
        let frameCount = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for index in 0..<frameCount {
                let sample = samples[index]
                sumOfSquares += sample * sample
            }
        }

        let meanSquare = sumOfSquares / Float(frameCount * channelCount)
        guard meanSquare > 0 else { return -.infinity }
        return 10 * log10(meanSquare)
    }
}
