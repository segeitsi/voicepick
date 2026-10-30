import Foundation

enum SubmissionError: LocalizedError {
    case unconfirmedInput, unconfirmedSend
    var errorDescription: String? {
        switch self {
        case .unconfirmedInput: return "Не удалось проверить вставленный текст. Ответ оставлен в поле ввода."
        case .unconfirmedSend: return "Отправка выполнена, но поле не очистилось. Проверь выбранное поле и заверши ввод вручную."
        }
    }
}

/// Called only after our own paste into an empty or previously owned composer.
/// Telegram Desktop may expose each pasted emoji as U+FFFC through AXValue.
@MainActor
enum Submission {
    static func equalText(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{FE0F}", with: "")
                .replacingOccurrences(of: "\u{FE0E}", with: "")
        }
        return normalized(lhs) == normalized(rhs)
    }

    static func pasteText(_ text: String, mode: RunMode) -> String {
        guard mode == .random, text.unicodeScalars.contains(where: {
            $0.properties.isEmoji && $0.value > 127
        }) else { return text }
        // Telegram offers stickers only when the entire composer is one emoji.
        // A trailing ordinary space prevents that popup while waiting for manual Enter.
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + " "
    }

    static func matchesPaste(_ value: String, _ text: String) -> Bool {
        // The random emoji draft must retain the space that suppresses autocomplete.
        guard !text.hasSuffix(" ") || value.hasSuffix(" ") else { return false }
        if equalText(value, text) { return true }
        func characters(_ string: String) -> [Character] {
            Array(string.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{FE0F}", with: "")
                .replacingOccurrences(of: "\u{FE0E}", with: ""))
        }
        let actual = characters(value), expected = characters(text)
        guard !expected.isEmpty, actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { rendered, requested in
            rendered == requested || (rendered == "\u{FFFC}" && requested.unicodeScalars.contains {
                $0.properties.isEmoji && $0.value > 127
            })
        }
    }

    static func confirmAndSubmit(
        _ text: String, mode: RunMode,
        sendReturn: Bool? = nil,
        read: () throws -> String?,
        pressReturn: () async throws -> Void,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws {
        var confirmedValue: String?
        for _ in 0..<15 {
            try Task.checkCancellation()
            if let value = try read() {
                if matchesPaste(value, text) { confirmedValue = value; break }
            }
            try await pause()
        }
        guard let confirmedValue else { throw SubmissionError.unconfirmedInput }
        guard mode.sendsReturn && (sendReturn ?? true) else { return }
        try Task.checkCancellation()
        guard try read() == confirmedValue else { throw SubmissionError.unconfirmedInput }
        try await pressReturn()
        for _ in 0..<15 {
            try await pause()
            try Task.checkCancellation()
            if let value = try read(), value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        }
        // Do not retry: a slow send must never become a second rating.
        throw SubmissionError.unconfirmedSend
    }
}
