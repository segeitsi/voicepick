import Foundation

@main
struct SubmissionTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1; if !condition { fatalError(label) }
        }
        var value = "", ticks = 0, returns = 0
        try await Submission.confirmAndSubmit("10", mode: .voice, read: { value }, pressReturn: {
            returns += 1; value = ""
        }, pause: {
            ticks += 1; if ticks == 7 { value = "10" }
        })
        check(returns == 1 && ticks == 8, "delayed numeric paste sends once")
        for text in ["❤️", "👎", "💌📹🎙"] {
            value = String(repeating: "\u{FFFC}", count: text.count); returns = 0
            try await Submission.confirmAndSubmit(text, mode: .voice, read: { value }, pressReturn: {
                returns += 1; value = ""
            }, pause: {})
            check(returns == 1, "own pasted emoji sends one Return without Copy or cursor keys")
        }
        for (text, rendered) in [("❤️", "\u{FFFC}"), ("5", "5")] {
            value = rendered; returns = 0
            try await Submission.confirmAndSubmit(text, mode: .random, read: { value }, pressReturn: {
                returns += 1
            }, pause: {})
            check(returns == 0 && value == rendered, "random leaves draft without Enter")
        }
        value = "5"; returns = 0
        try await Submission.confirmAndSubmit("5", mode: .voice, sendReturn: false, read: { value }, pressReturn: {
            returns += 1
        }, pause: {})
        check(returns == 0 && value == "5", "voice input can leave a value in an ordinary form without Enter")
        try await Submission.confirmAndSubmit("5", mode: .random, sendReturn: true, read: { value }, pressReturn: {
            returns += 1
        }, pause: {})
        check(returns == 0, "random mode cannot send even when Enter override is true")
        for emoji in ["❤️", "👎"] {
            let draft = Submission.pasteText(emoji, mode: .random)
            check(draft == emoji + " ", "random emoji suppresses sticker suggestions with ordinary space")
            value = "\u{FFFC} "; returns = 0
            try await Submission.confirmAndSubmit(draft, mode: .random, read: { value }, pressReturn: {
                returns += 1
            }, pause: {})
            check(returns == 0 && value == "\u{FFFC} ", "protected random draft remains unsubmitted")
            check(!Submission.matchesPaste("\u{FFFC}", draft), "missing protective space is rejected")
            check(Submission.pasteText(emoji, mode: .voice) == emoji, "voice payload unchanged")
        }
        check(Submission.pasteText("10", mode: .random) == "10", "numeric random draft unchanged")
        check(Submission.pasteText("❤️ ", mode: .random) == "❤️ ", "space not duplicated")
        for rendered in ["", "👎", "\u{FFFC}\u{FFFC}", "\u{FFFC} чужой текст"] {
            returns = 0
            do {
                try await Submission.confirmAndSubmit("❤️", mode: .voice, read: { rendered }, pressReturn: {
                    returns += 1
                }, pause: {})
                fatalError("empty, wrong or appended draft must fail")
            } catch SubmissionError.unconfirmedInput { }
            check(returns == 0, "mismatched draft never sent")
        }
        check(!Submission.matchesPaste("\u{FFFC}", "5"), "image cannot confirm numeric rating")
        check(Submission.matchesPaste("\u{FFFC} 5", "❤️ 5"), "mixed text preserves literal characters")
        check(!Submission.matchesPaste("\u{FFFC} 6", "❤️ 5"), "mixed text mismatch rejected")

        value = "5"; returns = 0
        do {
            try await Submission.confirmAndSubmit("5", mode: .voice, read: { value }, pressReturn: {
                returns += 1; value = "5\n"
            }, pause: {})
            fatalError("newline must not report success")
        } catch SubmissionError.unconfirmedSend { }
        check(returns == 1, "newline mode fails without duplicate send")
        value = "5"; ticks = 0; returns = 0
        try await Submission.confirmAndSubmit("5", mode: .voice, read: { value }, pressReturn: {
            returns += 1
        }, pause: {
            ticks += 1; if ticks == 10 { value = "" }
        })
        check(returns == 1 && ticks == 10, "slow send waits without duplicate Return")
        check(Submission.equalText("❤️", "❤"), "presentation variation accepted")
        returns = 0
        do {
            try await Submission.confirmAndSubmit("5", mode: .voice, read: { throw CancellationError() }, pressReturn: {
                returns += 1
            }, pause: {})
            fatalError("lost focus must cancel")
        } catch is CancellationError { }
        check(returns == 0, "lost focus does not send")
        print("PASS: \(checks) submission checks — rendered emoji, delayed AX, Enter, draft-only mode")
    }
}
