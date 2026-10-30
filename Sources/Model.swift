import SwiftUI
import AppKit
import ApplicationServices

struct Settings: Codable {
    var service = Service.bibinta
    var mode = RunMode.voice
    var minimum = 1
    var maximum = 10
    var likePercent = 50
    var likeEmoji = "❤️"
    var dislikeEmoji = "👎"
    var sensitivity = 0.09
    var calibrations: [String: Calibration] = [:]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings {
        didSet { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings.v1") } }
    }
    @Published var running = false
    @Published var preparing = false
    @Published var status = "Настрой поле ввода и выбери режим"
    @Published var heard = "Скажи число от 1 до 10"
    @Published var entries: [String] = []
    @Published var preview: NSImage?
    @Published var lastChoice = "—"
    @Published var accessibility = AccessibilityAccess.isGranted()
    @Published var screenAccess = CGPreflightScreenCaptureAccess()
    private var task: Task<Void, Never>?
    private var injection: Task<Void, Never>?
    private var queuedVoice: (command: VoiceCommand, time: TimeInterval)?
    private var runToken = UUID()
    private var monitor: Any?
    private var permissionTimer: Timer?
    private var waitingForAccessibility = false
    private var detector = ProfileDetector()
    private let selector = SelectionOverlay()
    private let writer = InputWriter()
    private let voice = VoiceListener()
    private var returnAfter = Date.distantPast
    var calibration: Calibration { settings.calibrations[settings.service.rawValue] ?? Calibration() }
    var localVoice: Bool { voice.usesLocalRecognition }

    init() {
        if let data = UserDefaults.standard.data(forKey: "settings.v1"),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) { settings = saved }
        else { settings = Settings() }
        voice.transcript = { [weak self] text in self?.heard = text }
        voice.command = { [weak self] command in self?.handle(command) }
        voice.failure = { [weak self] text in self?.stop(reason: text) }
        voice.reconnecting = { [weak self] in
            guard let self, self.running else { return }
            self.status = "Обновляю распознавание речи · микрофон включён"
        }
        if accessibility { installKeyboardMonitor() }
        permissionTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        }
        if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
    }

    private func installKeyboardMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            Task { @MainActor [weak self] in
                guard let self else { return }
                if code == 1 && modifiers == [.control, .option] {
                    self.stop(); NotificationCenter.default.post(name: .stopBBDV, object: nil); return
                }
                if (code == 36 || code == 76), modifiers.isEmpty,
                   self.running, self.settings.mode == .random,
                   Date() >= self.returnAfter, TargetWindow.current()?.resolved(self.calibration, mode: .random) != nil {
                    self.detector.manualReturn(); self.status = "Жду новую стабильную анкету…"
                }
            }
        }
    }

    func refreshPermissions() {
        let granted = AccessibilityAccess.isGranted()
        if accessibility != granted {
            accessibility = granted
            if granted { installKeyboardMonitor() }
            else {
                if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
                if running || preparing { stop(reason: "macOS отозвала доступ к управлению. Проверь настройки.") }
            }
        }
        if granted && waitingForAccessibility {
            waitingForAccessibility = false
            status = "Доступ к управлению получен · можно запускать"
        }
        let screenGranted = CGPreflightScreenCaptureAccess()
        if screenAccess != screenGranted { screenAccess = screenGranted }
    }
    func allowAccessibility() {
        waitingForAccessibility = true
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }
    func restartApp() {
        stop()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error { self.status = "Не удалось перезапустить: " + error.localizedDescription }
                else { NSApp.terminate(nil) }
            }
        }
    }
    func allowScreen() { screenAccess = CGRequestScreenCaptureAccess(); if !screenAccess { openPrivacy("Privacy_ScreenCapture") } }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }

    func calibrate(point: Bool) {
        guard !running, !preparing else { return }
        preparing = true
        let service = settings.service
        task = Task {
            do {
                for count in (1...4).reversed() {
                    status = "Открой нужного бота в Telegram · \(count)"
                    try await Task.sleep(for: .seconds(1))
                }
                guard let target = TargetWindow.current() else {
                    stop(reason: "На переднем плане должен быть Telegram с нужным ботом."); return
                }
                status = point ? "Выбери пустое поле сообщения" : "Выдели область анкеты"
                selector.select(point: point) { [weak self] rect in
                    guard let self else { return }
                    self.preparing = false; NSApp.activate(ignoringOtherApps: true)
                    guard let rect else { self.status = "Выбор отменён"; return }
                    guard point ? target.frame.contains(rect.origin) : target.frame.contains(rect) else {
                        self.status = "Выбери область внутри окна Telegram"; return
                    }
                    var calibration = self.settings.calibrations[service.rawValue] ?? Calibration()
                    if calibration.bundle != target.bundle || calibration.window != target.frame { calibration = Calibration() }
                    calibration.window = target.frame; calibration.bundle = target.bundle
                    calibration.windowIdentifier = target.identifier
                    if point { calibration.input = rect.origin } else { calibration.region = rect; self.preview = nil }
                    self.settings.calibrations[service.rawValue] = calibration
                    self.status = point ? "Поле ввода сохранено" : "Область анкеты сохранена"
                }
            } catch { preparing = false }
        }
    }

    func start() {
        guard !running, !preparing else { return }
        refreshPermissions()
        guard accessibility else {
            waitingForAccessibility = true
            status = "macOS пока не подтверждает доступ. Если он уже включён — смотри инструкцию ниже."
            return
        }
        installKeyboardMonitor()
        guard calibration.input != nil, calibration.window != nil else { status = "Сначала укажи поле ввода"; return }
        if settings.mode == .random {
            guard calibration.isComplete else { status = "Выдели область анкеты и поле в одном окне Telegram"; return }
            guard screenAccess else { status = "Разреши запись экрана и перезапусти приложение, если macOS попросит"; return }
        }
        if settings.service == .davinchik {
            guard !settings.likeEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !settings.dislikeEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = "Заполни оба эмодзи Давинчика"; return
            }
        }
        preparing = true; runToken = UUID(); let token = runToken
        task = Task {
            if settings.mode == .voice {
                status = "Проверяю разрешения микрофона и речи…"
                let allowed = await VoiceListener.authorize()
                guard runToken == token else { return }
                guard allowed else { stop(reason: "Разреши микрофон и распознавание речи в настройках macOS."); return }
            }
            do {
                for count in (1...4).reversed() {
                    status = "Открой \(settings.service.title) в Telegram · \(count)"
                    try await Task.sleep(for: .seconds(1))
                }
                _ = TargetWindow.activate(bundle: calibration.bundle)
                // Activation is asynchronous. Keep waiting instead of failing at
                // the exact end of the countdown while Telegram is coming forward.
                var resolved: Calibration?
                while resolved == nil, !Task.isCancelled, runToken == token {
                    if let target = TargetWindow.current(), target.bundle == calibration.bundle {
                        resolved = target.resolved(calibration, mode: settings.mode)
                        if resolved == nil {
                            let reason = settings.mode == .random
                                ? "Размер окна Telegram изменился. Заново выдели область анкеты и поле ввода."
                                : "В этом окне не найдено настроенное поле. Открой основной чат Telegram или укажи поле заново."
                            stop(reason: reason); return
                        }
                    } else { status = "Жду Telegram · открой нужного бота. Запуск продолжится автоматически." }
                    if resolved == nil { try await Task.sleep(for: .milliseconds(300)) }
                }
                try Task.checkCancellation()
                guard runToken == token, let resolved else { return }
                settings.calibrations[settings.service.rawValue] = resolved
                preparing = false; running = true
                if settings.mode == .voice {
                    voice.service = settings.service; try voice.start()
                    status = "Слушаю · отправка голосовых команд включена"
                    heard = settings.service == .bibinta ? "Скажи число от 1 до 10" : "Скажи «лайк» или «дизлайк»"
                    task = nil
                } else {
                    detector = ProfileDetector(threshold: settings.sensitivity)
                    status = "Жду стабильную анкету…"
                    await watchProfiles(token: token)
                }
            } catch is CancellationError { return }
            catch { stop(reason: error.localizedDescription) }
        }
    }

    func stop(reason: String = "Остановлено") {
        runToken = UUID(); running = false; preparing = false
        queuedVoice = nil
        task?.cancel(); task = nil; injection?.cancel(); injection = nil; voice.stop(); selector.cancel(); status = reason
    }

    /// Exercises activation and calibration without opening the microphone or typing.
    func checkTelegram() {
        guard !running, !preparing else { return }
        guard accessibility else { status = "Сначала восстанови доступ к управлению"; return }
        guard calibration.input != nil else { status = "Сначала укажи поле ввода"; return }
        preparing = true; runToken = UUID(); let token = runToken
        task = Task {
            _ = TargetWindow.activate(bundle: calibration.bundle)
            do {
                for _ in 0..<15 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard runToken == token else { return }
                    if let target = TargetWindow.current(), target.bundle == calibration.bundle {
                        if let resolved = target.resolved(calibration, mode: settings.mode) {
                            settings.calibrations[settings.service.rawValue] = resolved
                            status = "Telegram найден · привязка окна работает · можно запускать"
                        } else {
                            status = settings.mode == .random ? "Изменён размер Telegram — выдели анкету заново" : "Укажи поле ввода в основном окне Telegram заново"
                        }
                        preparing = false; task = nil; NSApp.activate(); return
                    }
                }
                preparing = false; task = nil; status = "Telegram не активировался. Открой нужный чат и попробуй снова."
                NSApp.activate()
            } catch { preparing = false }
        }
    }

    private func handle(_ command: VoiceCommand) {
        if command == .stop { stop(reason: "Остановлено голосом"); return }
        guard running, settings.mode == .voice else { return }
        guard let target = TargetWindow.current(), let resolved = target.resolved(calibration, mode: .voice) else {
            status = "Команда пропущена: вернись в Telegram"; return
        }
        if injection != nil {
            queuedVoice = (command, ProcessInfo.processInfo.systemUptime)
            return
        }
        let text: String
        switch command {
        case .rating(let value): text = String(value)
        case .like: text = settings.likeEmoji
        case .dislike: text = settings.dislikeEmoji
        case .stop: return
        }
        settings.calibrations[settings.service.rawValue] = resolved
        let token = runToken; let calibration = resolved
        injection = Task {
            defer {
                if runToken == token {
                    injection = nil
                    let next = queuedVoice; queuedVoice = nil
                    if let next, ProcessInfo.processInfo.systemUptime - next.time < 2 {
                        handle(next.command)
                    }
                }
            }
            do {
                try await writer.write(text, mode: .voice, calibration: calibration) {
                    self.running && self.runToken == token && self.settings.mode == .voice
                }
                lastChoice = text; log("Отправлено голосом: \(text)"); status = "Слушаю · команда отправлена"
            } catch is CancellationError { return }
            catch { stop(reason: error.localizedDescription) }
        }
    }

    var testMessage: String { settings.service == .bibinta ? "5" : settings.likeEmoji }

    /// Runs the same writer as speech recognition, with an explicit visible payload.
    func testVoiceSend() {
        guard !running, !preparing else { return }
        guard accessibility, calibration.input != nil else { status = "Проверь доступ и настрой поле ввода"; return }
        preparing = true; runToken = UUID()
        let token = runToken, text = testMessage
        task = Task {
            defer { if runToken == token { preparing = false; task = nil } }
            do {
                for count in (1...4).reversed() {
                    status = "Тест отправки \(text): открой нужного бота · \(count)"
                    try await Task.sleep(for: .seconds(1))
                }
                _ = TargetWindow.activate(bundle: calibration.bundle)
                var target: TargetWindow?
                for _ in 0..<15 {
                    try await Task.sleep(for: .milliseconds(100))
                    if let current = TargetWindow.current() { target = current; break }
                }
                guard let target, let resolved = target.resolved(calibration, mode: .voice) else {
                    throw DesktopError.message("Открой нужного бота в Telegram и повтори тест")
                }
                settings.calibrations[settings.service.rawValue] = resolved
                try await writer.write(text, mode: .voice, calibration: resolved) { self.runToken == token }
                lastChoice = text; log("Тест отправки: отправлено \(text)")
                status = "Отправка выполнена: \(text) отправлено, поле очистилось"
            } catch is CancellationError { return }
            catch { status = error.localizedDescription }
        }
    }

    private func watchProfiles(token: UUID) async {
        while running, runToken == token, !Task.isCancelled {
            do {
                guard let target = TargetWindow.current(), let resolved = target.resolved(calibration, mode: .random) else {
                    status = "Ожидание Telegram · при изменении размера заново выдели анкету"
                    try await Task.sleep(for: .milliseconds(600)); continue
                }
                guard let region = resolved.region else { return }
                let image = try await ScreenReader.capture(region)
                try Task.checkCancellation()
                guard running, runToken == token, TargetWindow.current()?.matches(resolved) == true else { continue }
                preview = NSImage(cgImage: image, size: region.size)
                let fingerprint = try ScreenReader.fingerprint(image)
                if detector.observe(fingerprint) {
                    let text = RandomChoice.value(service: settings.service, minimum: settings.minimum,
                                                  maximum: settings.maximum, likePercent: settings.likePercent,
                                                  like: settings.likeEmoji, dislike: settings.dislikeEmoji)
                    try await writer.write(text, mode: .random, calibration: resolved) {
                        self.running && self.runToken == token && self.settings.mode == .random
                    }
                    detector.commit(fingerprint); returnAfter = Date().addingTimeInterval(0.15)
                    lastChoice = text; log("Черновик: \(text) · Enter нажимаешь ты")
                    status = "Введено \(text) · нажми Enter в Telegram"
                }
                try await Task.sleep(for: .milliseconds(550))
            } catch is CancellationError { return }
            catch { stop(reason: error.localizedDescription); return }
        }
    }

    private func log(_ message: String) {
        entries.insert(Date().formatted(date: .omitted, time: .standard) + "  " + message, at: 0)
        entries = Array(entries.prefix(8))
    }
}
