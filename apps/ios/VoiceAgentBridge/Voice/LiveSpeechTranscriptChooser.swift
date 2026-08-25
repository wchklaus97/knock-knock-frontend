import Foundation

/// Picks between a device-locale transcript and a Chinese/English companion
/// transcript. Apple's on-device recognizer is monolingual, so mixed speech
/// needs both lanes.
enum LiveSpeechTranscriptChooser {
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCJK($0) }
    }

    static func choose(primary: String, companion: String) -> String {
        let left = normalized(primary)
        let right = normalized(companion)
        if left.isEmpty { return right }
        if right.isEmpty { return left }

        let leftScore = score(left)
        let rightScore = score(right)
        if leftScore == rightScore {
            return left.count >= right.count ? left : right
        }
        return leftScore > rightScore ? left : right
    }

    static func score(_ text: String) -> Int {
        let counts = scriptCounts(text)
        var value = counts.cjk * 4 + counts.latin
        if counts.cjk >= 1 && counts.latin >= 2 {
            value += 40
        }
        return value
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scriptCounts(_ text: String) -> (cjk: Int, latin: Int) {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else if CharacterSet.letters.contains(scalar), scalar.isASCII {
                latin += 1
            }
        }
        return (cjk, latin)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
            || (0x20000...0x2A6DF).contains(scalar.value)
    }
}
