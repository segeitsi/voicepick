import Foundation
import AVFoundation
import Speech

/// The audio tap stays installed while recognition requests are replaced.
/// Locking also prevents appending to a request after it has been ended.
private final class SpeechAudioRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }
}

@MainActor
final class VoiceListener {
    private let engine = AVAudioEngine()
    private let audio = SpeechAudioRouter()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var debounce: Task<Void, Never>?
    private var session = VoiceCommandSession(service: .bibinta)
    private var sessionEnded = false
    private var renewal: Task<Void, Never>?
    private var tapping = false
    private var active = false
    private var failures = 0
    var transcript: ((String) -> Void)?
    var command: ((VoiceCommand) -> Void)?
    var failure: ((String) -> Void)?
    var reconnecting: (() -> Void)?
    var service = Service.bibinta
    var usesLocalRecognition: Bool { recognizer?.supportsOnDeviceRecognition == true }

    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        active = true; failures = 0
        session = VoiceCommandSession(service: service)
        do {
            try beginRecognition()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw DesktopError.message("Микрофон не найден. Выбери устройство ввода в настройках звука macOS.")
            }
            let audio = self.audio
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in audio.append(buffer) }
            tapping = true; engine.prepare(); try engine.start()
        } catch { stop(); throw error }
    }

    func stop() {
        active = false; session.renew(); discardRecognition()
        engine.stop()
        if tapping { engine.inputNode.removeTap(onBus: 0); tapping = false }
    }

    private func discardRecognition() {
        debounce?.cancel(); renewal?.cancel(); debounce = nil; renewal = nil
        sessionEnded = false
        audio.set(nil)
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }

    private func beginRecognition() throws {
        guard active else { return }
        // Only replace speech recognition. Do not stop the engine or remove its tap.
        discardRecognition()
        guard let recognizer, recognizer.isAvailable else {
            throw DesktopError.message("Распознавание русского недоступно. Проверь интернет и настройки речи macOS.")
        }
        let token = session.token
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = ["один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять", "лайк", "дизлайк", "стоп", "пауза"]
        request.taskHint = .dictation
        self.request = request; audio.set(request)
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let errorText = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.active, self.session.token == token else { return }
                if let text {
                    self.failures = 0; self.transcript?(text)
                    self.session.observe(text, token: token, now: ProcessInfo.processInfo.systemUptime)
                }
                if final || errorText != nil { self.sessionEnded = true }
                if errorText != nil { self.failures = min(5, self.failures + 1) }
                self.scheduleCommand(token: token)
                if self.sessionEnded && self.session.deadline == nil {
                    if errorText != nil { self.reconnecting?() }
                    self.restart(after: errorText == nil ? 0 : min(2000, self.failures * 200))
                }
            }
        }
        renewal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.active, self.session.token == token else { return }
            if self.session.deadline != nil { self.sessionEnded = true }
            else { self.restart(after: 0) }
        }
    }

    private func scheduleCommand(token: UUID) {
        guard debounce == nil, let deadline = session.deadline else { return }
        debounce = Task { [weak self] in
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.active, self.session.token == token else { return }
            self.debounce = nil
            guard let parsed = self.session.takeDue(token: token, now: ProcessInfo.processInfo.systemUptime) else {
                self.scheduleCommand(token: token); return
            }
            // takeDue renews the cursor and invalidates old callbacks before dispatch.
            self.command?(parsed)
            guard self.active else { return }
            do { try self.beginRecognition() }
            catch { self.stop(); self.failure?(error.localizedDescription) }
        }
    }

    private func restart(after milliseconds: Int) {
        session.renew(); discardRecognition()
        renewal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
            guard let self, self.active else { return }
            self.renewal = nil
            do { try self.beginRecognition() }
            catch { self.stop(); self.failure?(error.localizedDescription) }
        }
    }
}
