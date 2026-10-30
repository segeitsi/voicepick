import Foundation

@main
struct VoiceCommandTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError("FAILED: " + message) }
        }
        func words(_ text: String) -> [String] { CommandParser.tokens(text) }
        var stream = VoiceCommandStream()
        stream.observe(words("бро ну эту"), now: 0)
        check(stream.deadline == nil, "surrounding speech alone does nothing")
        stream.observe(words("бро ну эту дизлайк"), now: 1)
        check(stream.takeDue(now: 1.2) == nil, "small settling delay")
        stream.observe(words("бро ну эту дизлайк вообще не мое"), now: 1.3)
        check(stream.deadline == 1.35, "continuing speech cannot move the deadline")
        check(stream.takeDue(now: 1.35) == .dislike, "dislike fires without a final result or silence")
        stream.observe(words("бро ну эту дизлайк вообще не мое идем дальше"), now: 2)
        check(stream.deadline == nil, "growing cumulative transcript cannot repeat the command")
        stream.observe(words("бро ну эту дизлайк вообще не мое идем дальше дизлайк"), now: 3)
        check(stream.takeDue(now: 3.35) == .dislike, "second spoken dislike in the same recognition task works")
        stream.observe(words("бро ну эту дизлайк вообще не мое идем дальше дизлайк лайк"), now: 4)
        check(stream.takeDue(now: 4.35) == .like, "old dislike cannot override a later like")

        stream = VoiceCommandStream()
        stream.observe(words("дизлайк"), now: 0)
        stream.observe(words("ну эту"), now: 0.2)
        check(stream.takeDue(now: 0.35) == .dislike, "temporary recognition revision cannot cancel a heard keyword")
        stream.observe(words("ну бро дизлайк"), now: 1)
        check(stream.deadline == nil, "revised surrounding words cannot repeat an already sent command")

        stream = VoiceCommandStream()
        stream.observe(words("дизлайк"), now: 0)
        stream.observe(words("лайк"), now: 0.2)
        check(stream.takeDue(now: 0.35) == .dislike, "partial revision cannot turn a heard dislike into a like")

        for phrase in ["ну дизлайк идем дальше", "дизлайк вообще не мое", "ну не нравится мне это",
                       "ставь диз лайк пожалуйста", "дис лайк идем дальше", "не лайк", "лайк нет дизлайк"] {
            stream = VoiceCommandStream()
            stream.observe(words(phrase), now: 0)
            check(stream.takeDue(now: 0.35) == .dislike, "phrase: " + phrase)
        }
        for phrase in ["лайк идем дальше", "ну нравится мне эта", "сердечко пожалуйста"] {
            stream = VoiceCommandStream()
            stream.observe(words(phrase), now: 0)
            check(stream.takeDue(now: 0.35) == .like, "phrase: " + phrase)
        }
        stream = VoiceCommandStream()
        stream.observe(words("лайк"), now: 0)
        stream.observe(words("лайк нет дизлайк"), now: 0.3)
        check(stream.takeDue(now: 0.35) == .dislike, "correction takes precedence without restarting the delay")
        stream = VoiceCommandStream()
        stream.observe(words("лайк ладно стоп дальше дизлайк"), now: 0)
        check(stream.takeDue(now: 0.35) == .stop, "stop inside a sentence cancels automatic commands")
        stream = VoiceCommandStream()
        stream.observe(words("дизлайки лайкнула перелайк"), now: 0)
        check(stream.deadline == nil, "no substring false positives")
        stream.observe(words("лайк"), now: 1)
        check(stream.takeDue(now: 1.35) == .like, "first adjacent command")
        stream.observe(words("лайк дизлайк"), now: 2)
        check(stream.takeDue(now: 2.35) == .dislike, "command immediately after the consumed word remains eligible")

        let ratings = ["один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять"]
        for (index, rating) in ratings.enumerated() {
            for value in [rating, String(index + 1)] {
                for phrase in [value + " идем дальше", "ну этой " + value + " идем дальше", "бро вообще " + value] {
                    stream = VoiceCommandStream(service: .bibinta)
                    stream.observe(words(phrase), now: 0)
                    check(stream.takeDue(now: 0.35) == .rating(index + 1), "Bibinta number anywhere: " + phrase)
                }
            }
        }
        stream = VoiceCommandStream(service: .bibinta)
        stream.observe(words("бро ну этой"), now: 0)
        check(stream.deadline == nil, "Bibinta waits for a number rather than arbitrary words")
        stream.observe(words("бро ну этой пять"), now: 1)
        stream.observe(words("бро ну этой пять короче идем дальше"), now: 1.3)
        check(stream.deadline == 1.35, "Bibinta continuation does not defer submission")
        check(stream.takeDue(now: 1.35) == .rating(5), "Bibinta submits while the sentence continues")
        stream.observe(words("бро ну этой пять короче идем дальше я еще говорю"), now: 2)
        check(stream.deadline == nil, "Bibinta cumulative updates do not resend the same rating")
        stream.observe(words("бро ну этой пять короче идем дальше я еще говорю пять"), now: 3)
        check(stream.takeDue(now: 3.35) == .rating(5), "Bibinta same number spoken again works without restarting recognition")
        stream.observe(words("бро ну этой пять короче идем дальше я еще говорю пять теперь восемь"), now: 4)
        check(stream.takeDue(now: 4.35) == .rating(8), "Bibinta next different number works without silence")
        stream = VoiceCommandStream(service: .bibinta)
        stream.observe(words("ну пять"), now: 0)
        stream.observe(words("ну я говорю"), now: 0.2)
        check(stream.takeDue(now: 0.35) == .rating(5), "Bibinta transient revision does not erase a heard rating")
        stream = VoiceCommandStream(service: .bibinta)
        stream.observe(words("ну пять"), now: 0)
        stream.observe(words("ну пять нет семь"), now: 0.3)
        check(stream.takeDue(now: 0.35) == .rating(7), "Bibinta quick correction sends the last number")
        stream = VoiceCommandStream(service: .bibinta)
        stream.observe(words("ну 5 нет 7"), now: 0)
        check(stream.takeDue(now: 0.35) == .rating(7), "Bibinta digit correction matches spoken word correction")
        for phrase in ["ну 0", "бро 11", "смотри 100", "пятьдесят вообще", "ну 1.5", "ну 1,5", "ну -5", "лайк дизлайк"] {
            stream = VoiceCommandStream(service: .bibinta)
            stream.observe(words(phrase), now: 0)
            check(stream.deadline == nil, "Bibinta ignores invalid numbers and other service commands: " + phrase)
        }
        stream = VoiceCommandStream(service: .bibinta)
        stream.observe(words("пять ладно стоп"), now: 0)
        check(stream.takeDue(now: 0.35) == .stop, "Bibinta stop inside a phrase prevents sending the rating")

        // Regression: macOS may give each new phrase a short transcript again.
        // A counter tied to one long transcript accepts the first rating then
        // incorrectly treats these later, genuinely new ratings as already sent.
        var session = VoiceCommandSession(service: .bibinta)
        var previousTokens: [UUID] = []
        for index in 0..<20 {
            let number = index % 10 + 1
            let token = session.token
            let now = Double(index) * 2
            let phrase = "ну этой " + ratings[number - 1] + " короче дальше"
            check(session.observe(phrase, token: token, now: now), "new request accepts rating \(index + 1)")
            session.observe(phrase + " я продолжаю говорить", token: token, now: now + 0.2)
            check(session.takeDue(token: token, now: now + 0.36) == .rating(number), "series rating \(index + 1) is submitted")
            check(session.token != token, "each submission renews recognition identity")
            check(session.deadline == nil, "new request begins with a clean command cursor")
            check(!session.observe(phrase, token: token, now: now + 0.4), "late partial result cannot submit twice")
            check(session.takeDue(token: token, now: now + 1) == nil, "late timer cannot submit twice")
            for stale in previousTokens {
                check(!session.observe("пять", token: stale, now: now + 1), "callbacks from all older requests remain invalid")
            }
            previousTokens.append(token)
        }
        session = VoiceCommandSession(service: .bibinta)
        for index in 0..<10 {
            let token = session.token, now = Double(index)
            session.observe("мяу мяу мяу три", token: token, now: now)
            check(session.takeDue(token: token, now: now + 0.36) == .rating(3), "ten identical phrases are ten separate commands")
        }
        let stale = session.token
        session.observe("ну пять", token: stale, now: 30)
        session.renew() // Final result/error/explicit stop invalidates the old request.
        check(session.takeDue(token: stale, now: 31) == nil, "renewal cancels an obsolete timer")
        check(!session.observe("ну пять", token: stale, now: 31), "old request cannot revive after restart")
        let renewed = session.token
        session.observe("ну восемь идем дальше", token: renewed, now: 32)
        check(session.takeDue(token: renewed, now: 32.36) == .rating(8), "recognition continues after a restart")
        session = VoiceCommandSession(service: .davinchik)
        for index in 0..<6 {
            let token = session.token, now = Double(index)
            session.observe("дизлайк идем дальше", token: token, now: now)
            check(session.takeDue(token: token, now: now + 0.36) == .dislike, "request renewal also preserves Davinchik commands")
        }
        print("PASS: \(checks) checks — streaming partial speech, fixed delay, revisions, repeated commands")
    }
}
