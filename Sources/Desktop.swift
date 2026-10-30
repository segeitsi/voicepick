import AppKit
import ApplicationServices
import ScreenCaptureKit

extension Notification.Name { static let stopVoicePick = Notification.Name("stopVoicePick") }

enum AccessibilityAccess {
    static func isGranted() -> Bool {
        let trusted = AXIsProcessTrustedWithOptions(nil)
        if trusted { return true }
        // A cached negative is stale only if both required capabilities work.
        // Read the application's role, never message or clipboard contents.
        let canPost = CGPreflightPostEventAccess()
        guard canPost, let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let readable = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success && value != nil
        return AccessibilityEvidence(trustedAPI: trusted, canPostEvents: canPost, canReadOtherApp: readable).granted
    }
}

struct Calibration: Codable {
    var region: CGRect?
    var input: CGPoint?
    var window: CGRect?
    var bundle: String?
    var windowIdentifier: String?
    var isComplete: Bool {
        guard let region, let input, let window else { return false }
        return region.width >= 80 && region.height >= 80 && window.contains(region) && window.contains(input)
    }

    func translated(to frame: CGRect) -> Calibration? {
        guard let original = window,
              abs(original.width - frame.width) <= 8,
              abs(original.height - frame.height) <= 8 else { return nil }
        let dx = frame.minX - original.minX, dy = frame.minY - original.minY
        var result = self
        result.window = frame
        result.input = input.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        result.region = region?.offsetBy(dx: dx, dy: dy)
        return result
    }

}

struct TargetWindow {
    let pid: pid_t
    let bundle: String
    let frame: CGRect
    var element: AXUIElement? = nil
    var identifier: String? = nil
    static func permits(bundle: String, expectedBundle: String?) -> Bool {
        guard !bundle.isEmpty, bundle != (Bundle.main.bundleIdentifier ?? "local.oshi.bbdv"),
              bundle != "local.oshi.bbdv", bundle != "com.apple.loginwindow" else { return false }
        return expectedBundle.map { bundle == $0 } ?? true
    }
    static func current(expectedBundle: String? = nil) -> TargetWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, permits(bundle: bundle, expectedBundle: expectedBundle) else { return nil }
        // Accessibility returns the actual focused window and works in voice mode
        // without Screen Recording permission. The window list is only a fallback.
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let value = AXRead.attribute(root, kAXFocusedWindowAttribute),
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            let window = value as! AXUIElement
            let subrole = AXRead.attribute(window, kAXSubroleAttribute) as? String
            if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { return nil }
            if let frame = AXRead.frame(window), frame.width > 200, frame.height > 200 {
                return TargetWindow(pid: app.processIdentifier, bundle: bundle, frame: frame,
                                    element: window, identifier: AXRead.attribute(window, kAXIdentifierAttribute) as? String)
            }
        }
        guard
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = bounds["X"]?.doubleValue, let y = bounds["Y"]?.doubleValue,
                  let w = bounds["Width"]?.doubleValue, let h = bounds["Height"]?.doubleValue,
                  w > 200, h > 200 else { continue }
            return TargetWindow(pid: app.processIdentifier, bundle: bundle,
                                frame: CGRect(x: x, y: y, width: w, height: h))
        }
        return nil
    }
    func matches(_ calibration: Calibration) -> Bool {
        guard bundle == calibration.bundle, let frame = calibration.window else { return false }
        if let saved = calibration.windowIdentifier, let identifier, saved != identifier { return false }
        return abs(self.frame.minX - frame.minX) < 3 && abs(self.frame.minY - frame.minY) < 3 &&
               abs(self.frame.width - frame.width) < 3 && abs(self.frame.height - frame.height) < 3
    }

    func resolved(_ calibration: Calibration, mode: RunMode) -> Calibration? {
        guard bundle == calibration.bundle, calibration.input != nil, calibration.window != nil else { return nil }
        if let saved = calibration.windowIdentifier, let identifier, saved != identifier { return nil }
        if var translated = calibration.translated(to: frame) {
            translated.windowIdentifier = identifier ?? calibration.windowIdentifier
            guard let point = translated.input, frame.contains(point) else { return nil }
            if mode == .random, !translated.isComplete { return nil }
            return translated
        }
        // Arbitrary layouts cannot safely infer a field after resize.
        return nil
    }

    @MainActor
    static func activate(bundle: String?) -> Bool {
        guard let bundle, permits(bundle: bundle, expectedBundle: bundle),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
        NSApp.yieldActivation(to: app)
        return app.activate(from: .current, options: [])
    }
}

enum AXRead {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

@MainActor
final class SelectionOverlay {
    private var panels: [NSPanel] = []
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var completion: ((CGRect?) -> Void)?

    func select(point: Bool, title: String? = nil, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        // AppKit uses a bottom-left origin; Quartz uses the main display's top-left.
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), point: point, title: title)
            view.done = { [weak self] rect in
                let global = CGRect(x: screen.frame.minX + rect.minX,
                                    y: mainTop - (screen.frame.minY + rect.maxY),
                                    width: rect.width, height: rect.height)
                self?.finish(global)
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(nil); return nil }
            return event
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.finish(nil) } }
        }
    }

    func cancel() { if !panels.isEmpty { finish(nil) } }

    private func finish(_ rect: CGRect?) {
        panels.forEach { $0.close() }; panels.removeAll()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        escapeMonitor = nil
        globalEscapeMonitor = nil
        let callback = completion; completion = nil; callback?(rect)
    }
}

private final class SelectionView: NSView {
    let point: Bool
    let title: String?
    var done: ((CGRect) -> Void)?
    private var start: CGPoint?
    private var end: CGPoint?
    init(frame: CGRect, point: Bool, title: String?) { self.point = point; self.title = title; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil); end = start; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { end = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        if point { done?(CGRect(x: end.x, y: end.y, width: 0, height: 0)); return }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(start.x - end.x), height: abs(start.y - end.y))
        if rect.width >= 80 && rect.height >= 80 { done?(rect) }
        else { self.start = nil; self.end = nil; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.48).setFill(); bounds.fill()
        if let start, let end, !point {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(start.x - end.x), height: abs(start.y - end.y))
            NSColor.systemMint.withAlphaComponent(0.18).setFill(); rect.fill()
            NSColor.systemMint.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 3; path.stroke()
        }
        let heading = title ?? (point ? "Кликни в пустое поле ввода" : "Обведи содержимое одной карточки")
        let text = heading + (title != nil ? "\nМожно выбрать область в любом приложении. Esc — отмена."
                              : point ? "\nВыбери текстовое поле для ответа. Esc — отмена."
                                      : "\nНе включай поле ввода и кнопки. Esc — отмена.")
        let style = NSMutableParagraphStyle(); style.alignment = .center
        (text as NSString).draw(in: CGRect(x: 40, y: bounds.maxY - 125, width: bounds.width - 80, height: 90),
                              withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                                               .foregroundColor: NSColor.white, .paragraphStyle: style])
    }
}

enum ScreenReader {
    static func capture(_ rect: CGRect) async throws -> CGImage {
        try await SCScreenshotManager.captureImage(in: rect)
    }

    static func localRegion(_ rect: CGRect, in display: CGRect) throws -> CGRect {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width >= 80, rect.height >= 80, display.contains(rect) else {
            throw DesktopError.message("Область вышла за границы экрана. Выдели её заново.")
        }
        return rect.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    /// Capture the composed desktop crop, including any app except our own windows.
    static func captureDesktopRegion(_ rect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(rect) }) else {
            throw DesktopError.message("Выбранная область больше не находится на экране. Выдели её заново.")
        }
        let local = try localRegion(rect, in: display.frame)
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local
        let pixelScale = max(1, Double(CGDisplayPixelsWide(display.displayID)) / display.frame.width)
        let scale = min(pixelScale, 1800 / max(rect.width, rect.height))
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.scalesToFit = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
    static func fingerprint(_ image: CGImage) throws -> Fingerprint {
        let size = 32
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let result: Fingerprint? = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            let pixels = buffer.bindMemory(to: UInt8.self)
            var samples: [Double] = []; samples.reserveCapacity(size * size * 3)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                samples.append(Double(pixels[i]) / 255)
                samples.append(Double(pixels[i + 1]) / 255)
                samples.append(Double(pixels[i + 2]) / 255)
            }
            return Fingerprint(samples: samples)
        }
        guard let result else { throw DesktopError.message("Не удалось обработать снимок.") }
        return result
    }
}

@MainActor
final class InputWriter {
    private(set) var lastDraft: String?
    private var lastDraftCalibration: Calibration?

    func write(_ text: String, mode: RunMode, calibration: Calibration, sendReturn: Bool? = nil, valid: () -> Bool) async throws {
        guard valid(), let target = TargetWindow.current(expectedBundle: calibration.bundle),
              let resolved = target.resolved(calibration, mode: mode), let point = resolved.input else {
            throw DesktopError.message("Не найдено настроенное поле. После изменения размера окна укажи поле ещё раз.")
        }
        // Click the calibrated field because another control may currently own focus.
        postMouse(.leftMouseDown, point); postMouse(.leftMouseUp, point)
        try await Task.sleep(for: .milliseconds(140))
        try Task.checkCancellation()
        guard valid(), TargetWindow.current(expectedBundle: resolved.bundle)?.matches(resolved) == true else { throw CancellationError() }
        let field = focusedField(pid: target.pid)
        guard let field, InputFieldPolicy.accepts(role: attribute(field, kAXRoleAttribute) as? String ?? "",
                                                 subrole: attribute(field, kAXSubroleAttribute) as? String) else {
            throw DesktopError.message("Не вижу доступное текстовое поле. Выбери обычное поле ввода и проверь Универсальный доступ.")
        }
        guard let contents = attribute(field, kAXValueAttribute) as? String else {
            throw DesktopError.message("Это приложение не даёт прочитать поле ввода через Универсальный доступ. Выбери другое поле или приложение.")
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never overwrite a user's existing message or send it with a rating appended.
        let previous = lastDraftCalibration.flatMap { target.resolved($0, mode: mode) }
        let sameTarget = previous?.input == resolved.input && previous?.windowIdentifier == resolved.windowIdentifier
        guard trimmed.isEmpty || (sameTarget && lastDraft.map({ Submission.equalText(trimmed, $0) }) == true) else {
            throw DesktopError.message("В поле уже есть текст. Отправь или очисти его вручную и запусти снова.")
        }
        if !trimmed.isEmpty { try await key(0, flags: .maskCommand); try await key(51) }
        let shouldSend = mode.sendsReturn && (sendReturn ?? true)
        let pasteText = Submission.pasteText(text, mode: shouldSend ? .voice : .random)
        let board = NSPasteboard.general
        let backup = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        board.clearContents(); board.setString(pasteText, forType: .string)
        let change = board.changeCount
        defer {
            // Do not clobber a copy the user made while the paste was in flight.
            if board.changeCount == change { board.clearContents(); board.writeObjects(backup) }
        }
        try await key(9, flags: .maskCommand)
        lastDraft = text
        lastDraftCalibration = resolved
        let originalFrame = AXRead.frame(field)
        let originalID = attribute(field, kAXIdentifierAttribute) as? String
        func readComposer() throws -> String? {
            try Task.checkCancellation()
            guard valid(), TargetWindow.current(expectedBundle: resolved.bundle)?.matches(resolved) == true,
                  let now = focusedField(pid: target.pid) else { throw CancellationError() }
            // Qt can recreate its AX wrapper after paste. Verify the stable field
            // identifier and position rather than requiring wrapper identity.
            let sameField = CFEqual(field, now) ||
                (originalID?.isEmpty == false && originalID == attribute(now, kAXIdentifierAttribute) as? String &&
                 originalFrame != nil && originalFrame == AXRead.frame(now))
            guard sameField else { throw DesktopError.message("Фокус ушёл из поля ввода. Ввод остановлен.") }
            return attribute(now, kAXValueAttribute) as? String
        }
        try await Submission.confirmAndSubmit(pasteText, mode: mode, sendReturn: shouldSend, read: readComposer, pressReturn: {
            _ = try readComposer()
            try await self.key(36)
        })
        if shouldSend { lastDraft = nil; lastDraftCalibration = nil }
    }

    private func focusedField(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func postMouse(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) async throws {
        try Task.checkCancellation()
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw DesktopError.message("Не удалось создать нажатие клавиши.")
        }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap)
        defer { up.post(tap: .cghidEventTap) }
        try await Task.sleep(for: .milliseconds(40))
    }
}
