import SwiftUI
import AppKit

@main
struct BBDVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var faceDebug = FaceDebugModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("ББ / ДВ", id: "main") {
            MainView(model: model, faceDebug: faceDebug).preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
                .onReceive(NotificationCenter.default.publisher(for: .stopBBDV)) { _ in model.stop() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
        }
        .defaultSize(width: 820, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Управление") {
                Button("Остановить") { model.stop(); NotificationCenter.default.post(name: .stopBBDV, object: nil) }.keyboardShortcut("s", modifiers: [.control, .option])
                Button("Перезапустить приложение") { model.restartApp() }
            }
        }
        MenuBarExtra("ББ / ДВ", systemImage: "viewfinder") {
            Text(faceDebug.watching ? "Наблюдение включено" : "Наблюдение на паузе")
            Text(faceDebug.status).font(.caption)
            Button("Выбрать область и наблюдать") { model.stop(); faceDebug.chooseRegion(immediate: true) }
            Button("Продолжить наблюдение") { model.stop(); faceDebug.watch() }
                .disabled(faceDebug.region == nil || faceDebug.watching || faceDebug.busy)
            Button("Остановить всё") { model.stop(); faceDebug.stop() }
            Divider()
            Button("Показать окно") { openWindow(id: "main"); NSApp.unhide(nil); NSApp.activate() }
            Button("Разрешить запись экрана") { faceDebug.allowScreen() }
            Button("Завершить ББ / ДВ") { model.stop(); faceDebug.stop(); NSApp.terminate(nil) }
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
    @State private var showsFaceDebug = true
    private let accent = Color(red: 0.64, green: 0.52, blue: 1)
    private let mint = Color(red: 0.40, green: 0.91, blue: 0.73)
    private var busy: Bool { model.running || model.preparing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack {
                    Button("Управление ботами") { faceDebug.stop(); showsFaceDebug = false }
                        .tint(showsFaceDebug ? .gray : accent)
                    Button("Оценка лица · отладка") { model.stop(); showsFaceDebug = true }
                        .tint(showsFaceDebug ? accent : .gray)
                }.buttonStyle(.bordered)
                if showsFaceDebug {
                    FaceDebugView(model: faceDebug)
                } else {
                HStack(spacing: 12) {
                    modeCard(.voice, title: "Голос", icon: "waveform", detail: "Сказал → ввёл → отправил")
                    modeCard(.random, title: "Рандомайзер", icon: "dice", detail: "Новая анкета → черновик")
                }.disabled(busy)
                HStack {
                    Text("БОТ").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Picker("Бот", selection: $model.settings.service) {
                        ForEach(Service.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 330).disabled(busy)
                    Spacer()
                    Text(model.settings.mode == .voice ? "Enter автоматически" : "Enter только вручную")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(model.settings.mode == .voice ? accent : mint)
                }
                configuration
                calibration
                control
                permissions
                if !model.entries.isEmpty { history }
                }
                Text("v1.3.1 · macOS · Ctrl+Option+S — стоп")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(28)
        }
        .background(Color(red: 0.065, green: 0.073, blue: 0.10))
        .frame(minWidth: 760, minHeight: 730)
        .onReceive(NotificationCenter.default.publisher(for: .stopBBDV)) { _ in faceDebug.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in faceDebug.stop() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ББ / ДВ").font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(showsFaceDebug ? "Категории по твоим эталонам." : "Твой голос. Твой выбор.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill((showsFaceDebug ? faceDebug.watching : model.running) ? mint : Color.gray).frame(width: 7, height: 7)
                Text(showsFaceDebug ? (faceDebug.watching ? "Наблюдаю" : faceDebug.busy ? "Анализ" : "На паузе") : (model.running ? "Работает" : model.preparing ? "Подготовка" : "На паузе")).font(.system(size: 12, weight: .medium))
            }.padding(.horizontal, 13).padding(.vertical, 8).background(.white.opacity(0.05), in: Capsule())
        }
    }

    private func modeCard(_ mode: RunMode, title: String, icon: String, detail: String) -> some View {
        Button { model.settings.mode = mode } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: icon).font(.system(size: 24)).foregroundStyle(model.settings.mode == mode ? accent : .secondary)
                    Spacer()
                    Image(systemName: model.settings.mode == mode ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.settings.mode == mode ? accent : .secondary)
                }
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(model.settings.mode == mode ? accent.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.settings.mode == mode ? accent.opacity(0.75) : Color.white.opacity(0.08)))
        }.buttonStyle(.plain)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.settings.service == .bibinta {
                if model.settings.mode == .voice {
                    Text("Говори число от 1 до 10 в любой части предложения.").font(.system(size: 14))
                    Text("Например: «Ну этой пять, идём дальше». Через 0,35 с число вводится и отправляется через Enter. Можно продолжать говорить. «Стоп» и «пауза» останавливают приложение.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Диапазон оценок").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Stepper("От \(model.settings.minimum)", value: $model.settings.minimum, in: 1...model.settings.maximum).frame(width: 120)
                        Stepper("До \(model.settings.maximum)", value: $model.settings.maximum, in: model.settings.minimum...10).frame(width: 120)
                    }
                    Text("Равномерный случайный выбор. Проверяешь оценку и сам нажимаешь Enter.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Лайк").font(.system(size: 13)); TextField("❤️", text: $model.settings.likeEmoji).textFieldStyle(.roundedBorder).frame(width: 85)
                    Text("Дизлайк").font(.system(size: 13)).padding(.leading, 16)
                    TextField("👎", text: $model.settings.dislikeEmoji).textFieldStyle(.roundedBorder).frame(width: 85)
                    Spacer()
                }
                if model.settings.mode == .random {
                    HStack {
                        Text("Вероятность лайка").font(.system(size: 13))
                        Slider(value: Binding(get: { Double(model.settings.likePercent) }, set: { model.settings.likePercent = Int($0) }), in: 0...100, step: 5)
                        Text("\(model.settings.likePercent)%").monospacedDigit().frame(width: 45)
                    }
                } else {
                    Text("«Лайк» / «нравится» → лайк. «Дизлайк» / «не нравится» / «пропуск» → дизлайк. Команда срабатывает внутри фразы через 0,35 с.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("Поставь эмодзи с кнопок своего бота. Приложение вставляет их в сообщение.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14)).disabled(busy)
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Настройка Telegram").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Для каждого бота отдельно").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { model.calibrate(point: true) } label: {
                    Label(model.calibration.input == nil ? "Указать поле ввода" : "Поле ввода ✓", systemImage: "cursorarrow.click")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }.disabled(busy)
                if model.settings.mode == .random {
                    Button { model.calibrate(point: false) } label: {
                        Label(model.calibration.region == nil ? "Выделить анкету" : "Область анкеты ✓", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.disabled(busy)
                }
            }
            Text("После нажатия у тебя 4 секунды, чтобы открыть нужного бота. Затем выбери место мышкой. Привязка следует за перемещением окна.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Проверить Telegram без отправки") { model.checkTelegram() }.disabled(busy).font(.system(size: 12))
            if model.settings.mode == .voice {
                DisclosureGroup("Проверка отправки") {
                    Text("Открой нужного бота. Тест вставит команду и отправит её через 4 секунды тем же способом, что голосовой режим.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Тест отправки: отправить \(model.testMessage)") { model.testVoiceSend() }
                        .disabled(busy).font(.system(size: 12))
                }.font(.system(size: 12))
            }
            if model.settings.mode == .random {
                DisclosureGroup("Проверка области и чувствительность") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let preview = model.preview {
                            Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else { Text("Предпросмотр появится после запуска.").font(.system(size: 12)).foregroundStyle(.secondary) }
                        HStack {
                            Text("Порог изменения").font(.system(size: 12))
                            Slider(value: $model.settings.sensitivity, in: 0.04...0.20, step: 0.01).disabled(busy)
                            Text(String(format: "%.0f%%", model.settings.sensitivity * 100)).frame(width: 45)
                        }
                        Text("Меньше — замечает небольшие изменения. Больше — меньше ложных срабатываний. Выделяй фото и текст одной анкеты, без кнопок и поля ввода.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }.font(.system(size: 12))
            }
        }.padding(18).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.status).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    if model.settings.mode == .voice {
                        Text("Распознано: \(model.heard)").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text("Последний выбор: \(model.lastChoice)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button { if busy { model.stop() } else { model.start() } } label: {
                    Label(busy ? "Стоп" : "Запустить", systemImage: busy ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 13)
                        .background(busy ? Color.red.opacity(0.8) : accent, in: RoundedRectangle(cornerRadius: 11))
                        .foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
            if model.settings.mode == .random {
                Label("Enter нажимаешь ты. После Enter ждём изменение анкеты.", systemImage: "keyboard")
                    .font(.system(size: 12)).foregroundStyle(mint)
            } else {
                Text(model.localVoice ? "Речь распознаётся на устройстве, если язык доступен в macOS." : "Речь распознаётся сервисом Apple; может понадобиться интернет.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(18).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 16) {
            Label("Доступы macOS", systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button(model.accessibility ? "Управление ✓" : "Разрешить управление") { model.allowAccessibility() }
            if model.settings.mode == .random {
                Button(model.screenAccess ? "Экран ✓" : "Разрешить экран") { model.allowScreen() }
            }
          }
          if !model.accessibility {
              Text("Тумблер уже включён? Перезапусти приложение. Если не помогло: удали только «ББ ДВ» из списка Универсального доступа кнопкой −, добавь текущую сборку через + и включи доступ снова.")
                  .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              HStack {
                  Button("Проверить доступ") { model.refreshPermissions() }
                  Button("Перезапустить") { model.restartApp() }
              }
          }
        }.font(.system(size: 11))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Последние действия").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                Text(entry).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}
