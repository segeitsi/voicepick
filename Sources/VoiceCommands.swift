import Foundation

/// Partial transcripts grow and revise themselves. Count command occurrences,
/// rather than waiting for a complete phrase or relying on partial audio timings.
struct VoiceCommandStream {
    static let delay: TimeInterval = 0.35
    let service: Service
    init(service: Service = .davinchik) { self.service = service }
    private struct Candidate {
        let command: VoiceCommand
        let occurrence: Int
    }
    private var consumedOccurrences = 0
    private var observedOccurrences = 0
    private var pending: Candidate?
    private(set) var deadline: TimeInterval?

    mutating func observe(_ words: [String], now: TimeInterval) {
        var occurrence = 0
        var candidate: Candidate?
        for index in words.indices {
            let pair = index > 0 ? words[index - 1] + " " + words[index] : ""
            let pairedCommand: VoiceCommand? = service == .davinchik && ["не нравится", "не лайк", "диз лайк", "дис лайк"].contains(pair) ? .dislike : nil
            let parsed = pairedCommand ?? CommandParser.parse(words[index], service: service)
            guard let parsed else { continue }
            occurrence += 1
            guard occurrence > consumedOccurrences else { continue }
            if candidate?.command == .dislike && parsed == .like { continue }
            candidate = Candidate(command: parsed, occurrence: occurrence)
            if parsed == .stop { break }
        }
        observedOccurrences = max(observedOccurrences, occurrence)
        guard let candidate else { return } // Transient revisions cannot erase a heard command.
        if pending?.command == .stop || (pending?.command == .dislike && candidate.command == .like) { return }
        pending = candidate
        if deadline == nil { deadline = now + Self.delay }
    }

    mutating func takeDue(now: TimeInterval) -> VoiceCommand? {
        guard let deadline, now >= deadline, let pending else { return nil }
        consumedOccurrences = max(consumedOccurrences, pending.occurrence, observedOccurrences)
        self.pending = nil; self.deadline = nil
        return pending.command
    }
}

/// Every submitted command belongs to one recognition request. Renewing the
/// request also invalidates late callbacks and gives the next rating a clean cursor.
struct VoiceCommandSession {
    let service: Service
    private(set) var token = UUID()
    private var stream: VoiceCommandStream
    var deadline: TimeInterval? { stream.deadline }

    init(service: Service) {
        self.service = service; stream = VoiceCommandStream(service: service)
    }

    mutating func renew() {
        token = UUID(); stream = VoiceCommandStream(service: service)
    }

    @discardableResult
    mutating func observe(_ text: String, token: UUID, now: TimeInterval) -> Bool {
        guard self.token == token else { return false }
        stream.observe(CommandParser.tokens(text), now: now)
        return true
    }

    mutating func takeDue(token: UUID, now: TimeInterval) -> VoiceCommand? {
        guard self.token == token, let command = stream.takeDue(now: now) else { return nil }
        renew()
        return command
    }
}
