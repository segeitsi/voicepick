import SwiftUI
import AppKit

@main
struct VoicePickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var faceDebug = FaceDebugModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("VoicePick", id: "main") {
            MainView(model: model, faceDebug: faceDebug).preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
                .onReceive(NotificationCenter.default.publisher(for: .stopVoicePick)) { _ in model.stop() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
        }
        .defaultSize(width: 980, height: 710)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Управление") {
                Button("Остановить") { model.stop(); NotificationCenter.default.post(name: .stopVoicePick, object: nil) }.keyboardShortcut("s", modifiers: [.control, .option])
                Button("Перезапустить приложение") { model.restartApp() }
            }
        }
        MenuBarExtra("VoicePick", systemImage: "viewfinder") {
            Text(faceDebug.watching ? "Наблюдение включено" : "Наблюдение на паузе")
            Text(faceDebug.status).font(.caption)
            Button("Выбрать область и наблюдать") { model.stop(); faceDebug.chooseRegion(immediate: true) }
            Button("Продолжить наблюдение") { model.stop(); faceDebug.watch() }
                .disabled(faceDebug.region == nil || faceDebug.watching || faceDebug.busy)
            Button("Остановить всё") { model.stop(); faceDebug.stop() }
            Divider()
            Button("Показать окно") { openWindow(id: "main"); NSApp.unhide(nil); NSApp.activate() }
            Button("Разрешить запись экрана") { faceDebug.allowScreen() }
            Button("Завершить VoicePick") { model.stop(); faceDebug.stop(); NSApp.terminate(nil) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var faceDebug: FaceDebugModel
    @State private var showsFaceDebug = false
    private var busy: Bool { model.running || model.preparing }
    private var isVoice: Bool { model.settings.mode == .voice }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if showsFaceDebug {
                            FaceDebugView(model: faceDebug)
                        } else {
                            responseSettings
                            calibration
                            permissions
                            if !model.entries.isEmpty { history }
                        }
                    }
                    .frame(maxWidth: 860)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(WorkspaceStyle.canvas)
        }
        .font(.system(size: 13))
        .tint(WorkspaceStyle.accent)
        .frame(minWidth: 830, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: .stopVoicePick)) { _ in faceDebug.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in faceDebug.stop() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(WorkspaceStyle.accent)
                    .frame(width: 36, height: 36)
                    .background(WorkspaceStyle.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text("VoicePick").font(.system(size: 18, weight: .semibold))
            }
            VStack(spacing: 4) {
                navigationButton("Голос", icon: "mic", selected: !showsFaceDebug && isVoice) {
                    showInput(.voice)
                }.disabled(busy && !isVoice)
                navigationButton("Рандомайзер", icon: "dice", selected: !showsFaceDebug && !isVoice) {
                    showInput(.random)
                }.disabled(busy && isVoice)
                navigationButton("Анализ лица", icon: "viewfinder", selected: showsFaceDebug) {
                    guard !showsFaceDebug else { return }
                    if busy { model.stop() }
                    showsFaceDebug = true
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Text("Остановить")
                    Spacer(minLength: 4)
                    Text("⌃⌥S").font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Остановить: Control Option S")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 20)
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(WorkspaceStyle.sidebar)
    }

    private func showInput(_ mode: RunMode) {
        if showsFaceDebug { faceDebug.stop() }
        if model.settings.mode != mode { model.settings.mode = mode }
        showsFaceDebug = false
    }

    private func navigationButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: icon).frame(width: 17)
            }
        }
        .buttonStyle(WorkspaceButtonStyle(selected ? .selected : .navigation))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(showsFaceDebug ? "Анализ лица" : isVoice ? "Голосовой ввод" : "Рандомайзер")
                    .font(.system(size: 28, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    let active = showsFaceDebug ? faceDebug.watching || faceDebug.busy : busy
                    Image(systemName: "circle.fill").font(.system(size: 6))
                        .foregroundStyle(active ? WorkspaceStyle.accent : .secondary)
                        .accessibilityHidden(true)
                    Text(showsFaceDebug ? faceDebug.status : model.status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !showsFaceDebug && model.running && isVoice {
                    Text(model.heard).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityLabel("Распознано: \(model.heard)")
                }
            }
            Spacer(minLength: 0)
            if showsFaceDebug {
                if faceDebug.busy || faceDebug.watching {
                    HStack(spacing: 8) {
                        if !faceDebug.busy {
                            Button("Открыть фото", systemImage: "photo") { faceDebug.openPhoto() }
                                .buttonStyle(WorkspaceButtonStyle())
                        }
                        Button("Остановить", systemImage: "stop.fill") { faceDebug.stop() }
                            .buttonStyle(WorkspaceButtonStyle(.stop))
                    }
                } else {
                    Button("Открыть фото", systemImage: "photo") { faceDebug.openPhoto() }
                        .buttonStyle(WorkspaceButtonStyle(.primary))
                }
            } else {
                Button(busy ? "Остановить" : "Запустить", systemImage: busy ? "stop.fill" : "play.fill") {
                    if busy { model.stop() } else { model.start() }
                }.buttonStyle(WorkspaceButtonStyle(busy ? .stop : .primary))
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var responseSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading("Формат ответа")
            Picker("Формат ответа", selection: $model.settings.inputKind) {
                ForEach(InputKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 350, alignment: .leading)

            if model.settings.inputKind == .reaction {
                HStack(spacing: 12) {
                    reactionField("Лайк", text: $model.settings.likeEmoji, placeholder: "❤️")
                    reactionField("Дизлайк", text: $model.settings.dislikeEmoji, placeholder: "👎")
                }
                .textFieldStyle(.roundedBorder)
                Text("Задай эмодзи, слово или короткий текст для каждой команды.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            if isVoice {
                Toggle("Нажимать Enter после ввода", isOn: $model.settings.sendReturn)
                    .toggleStyle(.switch)
                Text(model.settings.inputKind == .rating
                     ? "Скажи «поставь пять». VoicePick найдёт число в любой части фразы."
                     : "Скажи «лайк», «дизлайк» или «не нравится» в любой части фразы.")
                    .foregroundStyle(.secondary)
                if !model.localVoice {
                    Text("Для распознавания через Apple может понадобиться интернет.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                if model.settings.inputKind == .rating {
                    HStack(spacing: 20) {
                        Text("Диапазон оценок")
                        Spacer()
                        Stepper("От \(model.settings.minimum)", value: $model.settings.minimum, in: 1...model.settings.maximum)
                        Stepper("До \(model.settings.maximum)", value: $model.settings.maximum, in: model.settings.minimum...10)
                    }
                } else {
                    HStack(spacing: 14) {
                        Text("Вероятность лайка")
                        Slider(value: Binding(get: { Double(model.settings.likePercent) },
                                              set: { model.settings.likePercent = Int($0) }), in: 0...100, step: 5)
                            .accessibilityLabel("Вероятность лайка")
                        Text("\(model.settings.likePercent)%").monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                Text("VoicePick подставит ответ. Проверь его и нажми Enter.")
                    .foregroundStyle(.secondary)
            }
        }
        .workspacePanel()
        .disabled(busy)
    }

    private func reactionField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(title, text: text, prompt: Text(placeholder))
                .accessibilityLabel(title)
        }
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                WorkspaceHeading("Куда вводить")
                Spacer()
                Text(model.targetName).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(model.calibration.input == nil ? "Указать поле ввода" : "Выбрать поле заново",
                       systemImage: model.calibration.input == nil ? "cursorarrow.click" : "checkmark.circle") {
                    model.calibrate(point: true)
                }
                if !isVoice {
                    Button(model.calibration.region == nil ? "Выделить карточку" : "Выделить карточку заново",
                           systemImage: model.calibration.region == nil ? "viewfinder" : "checkmark.circle") {
                        model.calibrate(point: false)
                    }
                }
            }
            .buttonStyle(WorkspaceButtonStyle())
            .disabled(busy)
            Text(isVoice
                 ? "После нажатия открой нужное окно за 4 секунды и кликни в пустое поле."
                 : "Укажи пустое поле и обведи карточку в том же окне, без кнопок и поля ввода.")
                .foregroundStyle(.secondary)
            DisclosureGroup(isVoice ? "Проверка ввода" : "Проверка окна и чувствительность") {
                calibrationTools.padding(.top, 12)
            }
        }.workspacePanel()
    }

    private var calibrationTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("После изменения размера окна настрой привязку заново.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Проверить окно") { model.checkTarget() }
                if isVoice {
                    Button("Ввести \(model.testMessage)") { model.testVoiceInput() }
                }
            }.buttonStyle(WorkspaceButtonStyle()).disabled(busy)
            if isVoice {
                Text("Тест вставит ответ через 4 секунды. Enter зависит от переключателя выше.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Порог изменения")
                    Slider(value: $model.settings.sensitivity, in: 0.04...0.20, step: 0.01).disabled(busy)
                        .accessibilityLabel("Порог изменения")
                    Text(model.settings.sensitivity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                Text("Меньший порог помогает замечать небольшие изменения карточки.")
                    .foregroundStyle(.secondary)
                if let preview = model.preview {
                    Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Выбранная область карточки")
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label("Доступы macOS", systemImage: "lock.shield").fontWeight(.medium)
                Spacer()
                if !model.accessibility {
                    Button("Разрешить управление") { model.allowAccessibility() }
                } else {
                    Label("Управление разрешено", systemImage: "checkmark").foregroundStyle(.secondary)
                }
                if !isVoice {
                    if model.screenAccess {
                        Label("Экран разрешён", systemImage: "checkmark").foregroundStyle(.secondary)
                    } else {
                        Button("Разрешить запись экрана") { model.allowScreen() }
                    }
                }
            }.buttonStyle(WorkspaceButtonStyle())
            if !model.accessibility {
                DisclosureGroup("Доступ уже включён") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Перезапусти VoicePick. Если доступ не появится, заново добавь текущую сборку в список «Универсальный доступ» в настройках macOS.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Проверить доступ") { model.refreshPermissions() }
                            Button("Перезапустить") { model.restartApp() }
                        }.buttonStyle(WorkspaceButtonStyle())
                    }.padding(.top, 10)
                }
            }
        }.workspacePanel()
    }

    private var history: some View {
        DisclosureGroup("Последние действия") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                    Text(entry).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(.top, 12)
        }.workspacePanel()
    }
}
