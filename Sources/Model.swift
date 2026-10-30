import SwiftUI
import AppKit
import ApplicationServices

struct Settings: Codable {
    var inputKind = InputKind.rating
    var mode = RunMode.voice
    var sendReturn = false
    var minimum = 1
    var maximum = 10
    var likePercent = 50
    var likeEmoji = "❤️"
    var dislikeEmoji = "👎"
    var sensitivity = 0.09
    var calibrations: [String: Calibration] = [:]
    enum CodingKeys: String, CodingKey {
        case inputKind = "service"
        case mode, sendReturn, minimum, maximum, likePercent, likeEmoji, dislikeEmoji, sensitivity, calibrations
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputKind = try c.decodeIfPresent(InputKind.self, forKey: .inputKind) ?? .rating
        mode = try c.decodeIfPresent(RunMode.self, forKey: .mode) ?? .voice
        // Existing installations used automatic Enter before this option existed.
        sendReturn = try c.decodeIfPresent(Bool.self, forKey: .sendReturn) ?? true
        minimum = try c.decodeIfPresent(Int.self, forKey: .minimum) ?? 1
        maximum = try c.decodeIfPresent(Int.self, forKey: .maximum) ?? 10
        likePercent = try c.decodeIfPresent(Int.self, forKey: .likePercent) ?? 50
        likeEmoji = try c.decodeIfPresent(String.self, forKey: .likeEmoji) ?? "❤️"
        dislikeEmoji = try c.decodeIfPresent(String.self, forKey: .dislikeEmoji) ?? "👎"
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 0.09
        calibrations = try c.decodeIfPresent([String: Calibration].self, forKey: .calibrations) ?? [:]
    }
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
    var calibration: Calibration { settings.calibrations[settings.inputKind.rawValue] ?? Calibration() }
    var localVoice: Bool { voice.usesLocalRecognition }
    var targetName: String {
        guard let bundle = calibration.bundle else { return "Приложение ещё не выбрано" }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName ?? bundle
    }

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
                    self.stop(); NotificationCenter.default.post(name: .stopVoicePick, object: nil); return
                }
                if (code == 36 || code == 76), modifiers.isEmpty,
                   self.running, self.settings.mode == .random,
                   Date() >= self.returnAfter, TargetWindow.current(expectedBundle: calibration.bundle)?.resolved(self.calibration, mode: .random) != nil {
                    self.detector.manualReturn(); self.status = "Жду новую стабильную карточку…"
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
        let inputKind = settings.inputKind
        task = Task {
            do {
                for count in (1...4).reversed() {
                    status = "Открой приложение с полем ввода · \(count)"
                    try await Task.sleep(for: .seconds(1))
                }
                guard let target = TargetWindow.current() else {
                    stop(reason: "Открой нужное приложение на переднем плане."); return
                }
                status = point ? "Выбери пустое поле ввода" : "Выдели область карточки"
                selector.select(point: point) { [weak self] rect in
                    guard let self else { return }
                    self.preparing = false; NSApp.activate(ignoringOtherApps: true)
                    guard let rect else { self.status = "Выбор отменён"; return }
                    guard point ? target.frame.contains(rect.origin) : target.frame.contains(rect) else {
                        self.status = "Выбери область внутри выбранного окна"; return
                    }
                    var calibration = self.settings.calibrations[inputKind.rawValue] ?? Calibration()
                    if calibration.bundle != target.bundle || calibration.window != target.frame { calibration = Calibration() }
                    calibration.window = target.frame; calibration.bundle = target.bundle
                    calibration.windowIdentifier = target.identifier
                    if point { calibration.input = rect.origin } else { calibration.region = rect; self.preview = nil }
                    self.settings.calibrations[inputKind.rawValue] = calibration
                    self.status = point ? "Поле ввода сохранено" : "Область карточки сохранена"
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
            guard calibration.isComplete else { status = "Выдели карточку и поле ввода в одном окне"; return }
            guard screenAccess else { status = "Разреши запись экрана и перезапусти приложение, если macOS попросит"; return }
        }
        if settings.inputKind == .reaction {
            guard !settings.likeEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !settings.dislikeEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = "Заполни оба ответа: лайк и дизлайк"; return
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
                    status = "Открой \(targetName) · \(count)"
                    try await Task.sleep(for: .seconds(1))
                }
                _ = TargetWindow.activate(bundle: calibration.bundle)
                // Activation is asynchronous. Keep waiting instead of failing at
                // the exact end of the countdown while the selected app is coming forward.
                var resolved: Calibration?
                while resolved == nil, !Task.isCancelled, runToken == token {
                    if let target = TargetWindow.current(expectedBundle: calibration.bundle), target.bundle == calibration.bundle {
                        resolved = target.resolved(calibration, mode: settings.mode)
                        if resolved == nil {
                            let reason = settings.mode == .random
                                ? "Размер выбранного окна изменился. Выдели карточку и поле заново."
                                : "В этом окне не найдено настроенное поле. Открой выбранное окно или укажи поле заново."
                            stop(reason: reason); return
                        }
                    } else { status = "Жду выбранное приложение. Открой нужное окно, запуск продолжится автоматически." }
                    if resolved == nil { try await Task.sleep(for: .milliseconds(300)) }
                }
                try Task.checkCancellation()
                guard runToken == token, let resolved else { return }
                settings.calibrations[settings.inputKind.rawValue] = resolved
                preparing = false; running = true
                if settings.mode == .voice {
                    voice.inputKind = settings.inputKind; try voice.start()
                    status = settings.sendReturn ? "Слушаю, после ввода нажму Enter" : "Слушаю, ввожу ответ без Enter"
                    heard = settings.inputKind == .rating ? "Скажи число от 1 до 10" : "Скажи «лайк» или «дизлайк»"
                    task = nil
                } else {
                    detector = ProfileDetector(threshold: settings.sensitivity)
                    status = "Жду стабильную карточку…"
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
    func checkTarget() {
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
                    if let target = TargetWindow.current(expectedBundle: calibration.bundle), target.bundle == calibration.bundle {
                        if let resolved = target.resolved(calibration, mode: settings.mode) {
                            settings.calibrations[settings.inputKind.rawValue] = resolved
                            status = "Выбранное окно найдено, можно запускать"
                        } else {
                            status = settings.mode == .random ? "Размер окна изменился, выбери карточку и поле заново" : "Укажи поле ввода в выбранном окне заново"
                        }
                        preparing = false; task = nil; NSApp.activate(); return
                    }
                }
                preparing = false; task = nil; status = "Не удалось активировать выбранное окно. Открой приложение и попробуй снова."
                NSApp.activate()
            } catch { preparing = false }
        }
    }

    private func handle(_ command: VoiceCommand) {
        if command == .stop { stop(reason: "Остановлено голосом"); return }
        guard running, settings.mode == .voice else { return }
        guard let target = TargetWindow.current(expectedBundle: calibration.bundle), let resolved = target.resolved(calibration, mode: .voice) else {
            status = "Команда пропущена: вернись в выбранное приложение"; return
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
        settings.calibrations[settings.inputKind.rawValue] = resolved
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
                try await writer.write(text, mode: .voice, calibration: calibration, sendReturn: settings.sendReturn) {
                    self.running && self.runToken == token && self.settings.mode == .voice
                }
                lastChoice = text
                log(settings.sendReturn ? "Введено голосом с Enter: \(text)" : "Введено голосом: \(text)")
                status = "Слушаю, ответ введён"
            } catch is CancellationError { return }
            catch { stop(reason: error.localizedDescription) }
        }
    }

    var testMessage: String { settings.inputKind == .rating ? "5" : settings.likeEmoji }

    /// Runs the same writer as speech recognition, with an explicit visible payload.
    func testVoiceInput() {
        guard !running, !preparing else { return }
        guard accessibility, calibration.input != nil else { status = "Проверь доступ и настрой поле ввода"; return }
        preparing = true; runToken = UUID()
        let token = runToken, text = testMessage
        task = Task {
            defer { if runToken == token { preparing = false; task = nil } }
            do {
                for count in (1...4).reversed() {
                    status = "Тест ввода \(text): открой выбранное приложение · \(count)"
                    try await Task.sleep(for: .seconds(1))
                }
                _ = TargetWindow.activate(bundle: calibration.bundle)
                var target: TargetWindow?
                for _ in 0..<15 {
                    try await Task.sleep(for: .milliseconds(100))
                    if let current = TargetWindow.current(expectedBundle: calibration.bundle) { target = current; break }
                }
                guard let target, let resolved = target.resolved(calibration, mode: .voice) else {
                    throw DesktopError.message("Открой приложение с полем ввода и повтори тест")
                }
                settings.calibrations[settings.inputKind.rawValue] = resolved
                try await writer.write(text, mode: .voice, calibration: resolved, sendReturn: settings.sendReturn) { self.runToken == token }
                lastChoice = text; log("Тест ввода: \(text)")
                status = settings.sendReturn ? "Ответ введён с Enter, поле очистилось" : "Ответ введён без Enter"
            } catch is CancellationError { return }
            catch { status = error.localizedDescription }
        }
    }

    private func watchProfiles(token: UUID) async {
        while running, runToken == token, !Task.isCancelled {
            do {
                guard let target = TargetWindow.current(expectedBundle: calibration.bundle), let resolved = target.resolved(calibration, mode: .random) else {
                    status = "Жду выбранное окно, после изменения размера выбери область заново"
                    try await Task.sleep(for: .milliseconds(600)); continue
                }
                guard let region = resolved.region else { return }
                let image = try await ScreenReader.capture(region)
                try Task.checkCancellation()
                guard running, runToken == token, TargetWindow.current(expectedBundle: calibration.bundle)?.matches(resolved) == true else { continue }
                preview = NSImage(cgImage: image, size: region.size)
                let fingerprint = try ScreenReader.fingerprint(image)
                if detector.observe(fingerprint) {
                    let text = RandomChoice.value(inputKind: settings.inputKind, minimum: settings.minimum,
                                                  maximum: settings.maximum, likePercent: settings.likePercent,
                                                  like: settings.likeEmoji, dislike: settings.dislikeEmoji)
                    try await writer.write(text, mode: .random, calibration: resolved) {
                        self.running && self.runToken == token && self.settings.mode == .random
                    }
                    detector.commit(fingerprint); returnAfter = Date().addingTimeInterval(0.15)
                    lastChoice = text; log("Черновик: \(text) · Enter нажимаешь ты")
                    status = "Введено \(text) · нажми Enter в выбранном поле"
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
