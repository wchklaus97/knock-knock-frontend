import Foundation

enum VoiceLanguage: String, CaseIterable, Equatable {
    case englishHongKong = "en-HK"
    case mandarinSimplified = "zh-Hans-CN"
    case cantoneseTraditional = "yue-Hant-HK"

    init?(locale: Locale) {
        let identifier = locale.identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if identifier.hasPrefix("yue") || identifier == "zh-hk" {
            self = .cantoneseTraditional
        } else if identifier.hasPrefix("zh") {
            self = .mandarinSimplified
        } else if identifier.hasPrefix("en") {
            self = .englishHongKong
        } else {
            return nil
        }
    }
}

enum RoutedSpeechBackend: String, Equatable {
    case appleSpeechAnalyzer = "apple_speech_analyzer"
    case senseVoice = "sensevoice_small_cantonese_int8"
    case systemSpeech = "system_speech"
}

struct VoiceLanguageRoute: Equatable {
    let language: VoiceLanguage
    let backend: RoutedSpeechBackend
    let fallbackBackend: RoutedSpeechBackend?
    let outputLocale: String
    let requiresStrictClarification: Bool
}

/// Frozen from the 120-clip, same-corpus physical-device comparison.
/// A backend may be selected only when its model/runtime is actually ready;
/// otherwise the route is fail-safe and requires strict clarification.
enum VoiceLanguageRoutingPolicy {
    static func route(
        language: VoiceLanguage,
        supportsSpeechAnalyzer: Bool,
        senseVoiceReady: Bool
    ) -> VoiceLanguageRoute {
        switch language {
        case .englishHongKong:
            return VoiceLanguageRoute(
                language: language,
                backend: supportsSpeechAnalyzer ? .appleSpeechAnalyzer : .systemSpeech,
                fallbackBackend: nil,
                outputLocale: language.rawValue,
                // 89.46% on the public corpus: best candidate, but below the
                // 90% locale gate. Entities and high-risk commands must clarify.
                requiresStrictClarification: true
            )

        case .mandarinSimplified:
            if senseVoiceReady {
                return VoiceLanguageRoute(
                    language: language,
                    backend: .senseVoice,
                    fallbackBackend: supportsSpeechAnalyzer ? .appleSpeechAnalyzer : .systemSpeech,
                    outputLocale: language.rawValue,
                    requiresStrictClarification: false
                )
            }
            return VoiceLanguageRoute(
                language: language,
                backend: supportsSpeechAnalyzer ? .appleSpeechAnalyzer : .systemSpeech,
                fallbackBackend: nil,
                outputLocale: language.rawValue,
                // Apple reached 87.25%, so a missing SenseVoice artifact must
                // never silently downgrade into an execution-ready transcript.
                requiresStrictClarification: true
            )

        case .cantoneseTraditional:
            return VoiceLanguageRoute(
                language: language,
                backend: supportsSpeechAnalyzer ? .appleSpeechAnalyzer : .systemSpeech,
                fallbackBackend: senseVoiceReady ? .senseVoice : nil,
                outputLocale: language.rawValue,
                requiresStrictClarification: !supportsSpeechAnalyzer
            )
        }
    }
}

enum VoiceTranscriptNormalizer {
    static func normalize(_ transcript: String, for language: VoiceLanguage) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language == .cantoneseTraditional else { return trimmed }
        return trimmed.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? trimmed
    }
}
