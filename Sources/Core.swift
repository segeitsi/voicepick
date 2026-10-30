import Foundation

enum InputKind: String, Codable, CaseIterable {
    // Preserve stored keys from releases before the VoicePick name.
    case rating = "bibinta", reaction = "davinchik"
    var title: String { self == .rating ? "Число 1–10" : "Лайк / дизлайк" }
}

enum InputFieldPolicy {
    static func accepts(role: String, subrole: String?) -> Bool {
        ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) && subrole != "AXSecureTextField"
    }
}

enum RunMode: String, Codable, CaseIterable {
    case voice, random
    var sendsReturn: Bool { self == .voice }
}

struct AccessibilityEvidence {
    let trustedAPI: Bool
    let canPostEvents: Bool
    let canReadOtherApp: Bool
    var granted: Bool { trustedAPI || (canPostEvents && canReadOtherApp) }
}

enum VoiceCommand: Equatable {
    case rating(Int), like, dislike, stop
}

enum CommandParser {
    private static let wordPattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])[+-]?\d+(?:[.,]\d+)?(?![\p{L}\p{N}])|[\p{L}\p{N}]+"#)

    static func tokens(_ text: String) -> [String] {
        let normalized = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let range = NSRange(normalized.startIndex..., in: normalized)
        return wordPattern.matches(in: normalized, range: range).compactMap {
            Range($0.range, in: normalized).map { String(normalized[$0]) }
        }
    }

    static func parse(_ text: String, inputKind: InputKind) -> VoiceCommand? {
        let words = tokens(text)
        if words.contains(where: { ["стоп", "пауза", "остановись"].contains($0) }) { return .stop }
        let normalized = words.joined(separator: " ")
        return parseInputKind(normalized, inputKind: inputKind)
    }

    private static func parseInputKind(_ normalized: String, inputKind: InputKind) -> VoiceCommand? {
        if inputKind == .rating {
            let words = ["один": 1, "единица": 1, "два": 2, "двойка": 2,
                         "три": 3, "тройка": 3, "четыре": 4, "четверка": 4,
                         "пять": 5, "пятерка": 5, "шесть": 6, "шестерка": 6,
                         "семь": 7, "семерка": 7, "восемь": 8, "восьмерка": 8,
                         "девять": 9, "девятка": 9, "десять": 10, "десятка": 10]
            // The last rating in the short settling interval allows "пять, нет, семь".
            for value in normalized.split(separator: " ").reversed().map(String.init) {
                if let number = words[value] { return .rating(number) }
                if let number = Int(value), (1...10).contains(number) { return .rating(number) }
            }
        } else {
            let tokens = normalized.split(separator: " ").map(String.init)
            func hasPhrase(_ phrase: [String]) -> Bool {
                guard tokens.count >= phrase.count else { return false }
                return (0...(tokens.count - phrase.count)).contains {
                    Array(tokens[$0..<($0 + phrase.count)]) == phrase
                }
            }
            // Match complete command words inside speech, with dislike before like.
            if tokens.contains(where: { ["дизлайк", "дислайк", "пропуск", "пропустить", "пас"].contains($0) }) ||
                [["не", "нравится"], ["не", "лайк"], ["диз", "лайк"], ["дис", "лайк"]].contains(where: hasPhrase) {
                return .dislike
            }
            if tokens.contains(where: { ["лайк", "нравится", "сердце", "сердечко"].contains($0) }) { return .like }
        }
        return nil
    }
}

struct Fingerprint: Equatable {
    let samples: [Double]
    func distance(to other: Self) -> Double {
        guard !samples.isEmpty, samples.count == other.samples.count else { return 1 }
        return zip(samples, other.samples).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(samples.count)
    }
    var hasDetail: Bool {
        guard !samples.isEmpty else { return false }
        let mean = samples.reduce(0, +) / Double(samples.count)
        return samples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(samples.count) > 0.002
    }
}

/// A stable visible card is offered once; another offer requires a manual Return
/// AND a substantial visual change. The draft is committed only after injection succeeds.
struct ProfileDetector {
    var threshold: Double = 0.09
    var requiredStableFrames = 3
    private(set) var committed: Fingerprint?
    private var candidate: Fingerprint?
    private var stableFrames = 0
    private(set) var armed = true

    init(threshold: Double = 0.09, requiredStableFrames: Int = 3) {
        self.threshold = threshold
        self.requiredStableFrames = requiredStableFrames
    }

    mutating func observe(_ frame: Fingerprint) -> Bool {
        guard armed, frame.hasDetail else { candidate = nil; stableFrames = 0; return false }
        if let committed, frame.distance(to: committed) < threshold {
            candidate = nil; stableFrames = 0; return false
        }
        if let candidate, frame.distance(to: candidate) < 0.025 { stableFrames += 1 }
        else { candidate = frame; stableFrames = 1 }
        return stableFrames >= requiredStableFrames
    }

    mutating func commit(_ frame: Fingerprint) {
        committed = frame; candidate = nil; stableFrames = 0; armed = false
    }

    mutating func manualReturn() {
        guard !armed else { return }
        armed = true; candidate = nil; stableFrames = 0
    }
}

enum RandomChoice {
    static func value(inputKind: InputKind, minimum: Int, maximum: Int, likePercent: Int,
                      like: String, dislike: String) -> String {
        if inputKind == .rating {
            let lower = min(10, max(1, minimum))
            let upper = min(10, max(lower, maximum))
            return String(Int.random(in: lower...upper))
        }
        return Int.random(in: 0..<100) < min(100, max(0, likePercent)) ? like : dislike
    }
}
