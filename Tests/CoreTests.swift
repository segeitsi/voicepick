import Foundation

@main
struct CoreTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            checks += 1
            guard condition() else { fatalError("FAILED: " + description) }
        }
        let words = ["один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять"]
        for (i, word) in words.enumerated() {
            check(CommandParser.parse(word, service: .bibinta) == .rating(i + 1), word)
            check(CommandParser.parse(String(i + 1), service: .bibinta) == .rating(i + 1), String(i + 1))
        }
        check(CommandParser.parse("Оценка пять!", service: .bibinta) == .rating(5), "prefix and punctuation")
        check(CommandParser.parse("четвёрка", service: .bibinta) == .rating(4), "ё normalization")
        for phrase in ["0", "11", "100", "пятьдесят", "1.5", "1,5", "-5", "15abc", "abc5", ""] {
            check(CommandParser.parse(phrase, service: .bibinta) == nil, "reject unrelated speech: " + phrase)
        }
        for (phrase, number) in [("ну этой пять идем дальше", 5), ("5 вот так", 5),
                                 ("мне пять лет", 5), ("пять шесть", 6),
                                 ("оценка пять или шесть", 6), ("бро давай 10 пожалуйста", 10)] {
            check(CommandParser.parse(phrase, service: .bibinta) == .rating(number), "number inside speech: " + phrase)
        }
        check(CommandParser.parse("не нравится", service: .davinchik) == .dislike, "negated like")
        check(CommandParser.parse("лайк", service: .davinchik) == .like, "like")
        check(CommandParser.parse("дизлайк", service: .davinchik) == .dislike, "dislike")
        for phrase in ["ну эту дизлайк", "дизлайк идем дальше", "бро дизлайк вообще не мое", "ДИСЛАЙК! вот так", "не нравится мне это", "ставь диз лайк", "не лайк"] {
            check(CommandParser.parse(phrase, service: .davinchik) == .dislike, "dislike inside sentence: " + phrase)
        }
        for phrase in ["ну лайк ей", "сердечко и дальше", "мне нравится эта анкета"] {
            check(CommandParser.parse(phrase, service: .davinchik) == .like, "like inside sentence: " + phrase)
        }
        check(CommandParser.parse("лайк нет дизлайк", service: .davinchik) == .dislike, "dislike wins over like")
        for phrase in ["лайкнула", "дизлайки", "перелайк", "лайкать", "нравитсяли"] {
            check(CommandParser.parse(phrase, service: .davinchik) == nil, "whole words only: " + phrase)
        }
        check(CommandParser.parse("пять", service: .davinchik) == nil, "rating not in Davinchik")
        check(CommandParser.parse("лайк", service: .bibinta) == nil, "like not in Bibinta")
        for service in Service.allCases {
            check(CommandParser.parse("стоп", service: service) == .stop, "stop")
            check(CommandParser.parse("пауза", service: service) == .stop, "pause")
        }
        check(!RunMode.random.sendsReturn, "random must never submit")
        check(RunMode.voice.sendsReturn, "voice submits")
        check(AccessibilityEvidence(trustedAPI: true, canPostEvents: false, canReadOtherApp: false).granted, "trusted API accepted")
        check(AccessibilityEvidence(trustedAPI: false, canPostEvents: true, canReadOtherApp: true).granted, "actual permissions accepted despite cached negative")
        check(!AccessibilityEvidence(trustedAPI: false, canPostEvents: true, canReadOtherApp: false).granted, "event posting alone insufficient")
        check(!AccessibilityEvidence(trustedAPI: false, canPostEvents: false, canReadOtherApp: true).granted, "AX read alone insufficient")
        check(!AccessibilityEvidence(trustedAPI: false, canPostEvents: false, canReadOtherApp: false).granted, "denied permissions stay denied")

        let cardA = Fingerprint(samples: [0.1, 0.8, 0.2, 0.6])
        let cardB = Fingerprint(samples: [0.9, 0.2, 0.7, 0.3])
        let flicker = Fingerprint(samples: [0.11, 0.81, 0.21, 0.61])
        let blank = Fingerprint(samples: [0.5, 0.5, 0.5, 0.5])
        var detector = ProfileDetector()
        check(!detector.observe(blank), "ignore loading/blank frame")
        check(!detector.observe(cardA), "first frame not stable")
        check(!detector.observe(cardA), "second frame not stable")
        check(detector.observe(cardA), "third frame stable")
        // Observe does not commit an unsuccessful injection.
        check(detector.observe(cardA), "failed injection remains eligible")
        detector.commit(cardA)
        for _ in 0..<5 { check(!detector.observe(cardB), "no new choice before manual Enter") }
        detector.manualReturn()
        for _ in 0..<5 { check(!detector.observe(flicker), "old card after Enter is not a new profile") }
        check(!detector.observe(cardB), "new card must settle")
        check(!detector.observe(cardA), "transient change resets candidate")
        check(!detector.observe(cardB), "restart settling after transient")
        check(!detector.observe(cardB), "second new frame")
        check(detector.observe(cardB), "new stable card after manual Enter")
        detector.commit(cardB)
        check(!detector.armed, "second card disarmed")
        for _ in 0..<1000 {
            let value = RandomChoice.value(service: .bibinta, minimum: 4, maximum: 7, likePercent: 50, like: "L", dislike: "D")
            check((4...7).contains(Int(value)!), "random rating in bounds")
        }
        check(RandomChoice.value(service: .davinchik, minimum: 1, maximum: 10, likePercent: 0, like: "L", dislike: "D") == "D", "0% likes")
        check(RandomChoice.value(service: .davinchik, minimum: 1, maximum: 10, likePercent: 100, like: "L", dislike: "D") == "L", "100% likes")
        check(RandomChoice.value(service: .bibinta, minimum: 10, maximum: 1, likePercent: 50, like: "L", dislike: "D") == "10", "invalid stored range is clamped")
        print("PASS: \(checks) checks — commands, settling, re-arming, random ranges, submission policy")
    }
}
