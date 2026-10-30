import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class FaceDebugModel: ObservableObject {
    @Published var result: FaceAnalysisResult?
    @Published var selected: Int?
    @Published var status = "Открой фото или выдели область экрана в любом приложении"
    @Published var watching = false
    @Published var busy = false
    @Published var excluded: Set<String> = []
    @Published var region: CGRect?
    @Published var showsLandmarks = true
    @Published var kind: ReferenceKind = .photo
    @Published var referenceTier: FaceTier = .mtb
    @Published var match: ReferenceMatch?
    @Published var matching = false
    let referenceStore = FaceReferenceStore()
    private var matchTask: Task<Void, Never>?
    private var matchToken = UUID()
    private let selector = SelectionOverlay()
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var stopObserver: NSObjectProtocol?
    private let capture: (CGRect) async throws -> CGImage
    private let analyze: (CGImage) async throws -> FaceAnalysisResult
    private let canCapture: () -> Bool
    private let pollInterval: Duration

    init(capture: @escaping (CGRect) async throws -> CGImage = ScreenReader.captureDesktopRegion,
         analyze: @escaping (CGImage) async throws -> FaceAnalysisResult = { image in
             try await Task.detached(priority: .userInitiated) { try LocalFaceAnalyzer.analyze(image) }.value
         }, canCapture: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         pollInterval: Duration = .milliseconds(900)) {
        self.capture = capture; self.analyze = analyze; self.canCapture = canCapture; self.pollInterval = pollInterval
        stopObserver = NotificationCenter.default.addObserver(forName: .stopVoicePick, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    deinit { if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) } }
    var face: AnalyzedFace? {
        guard let detected = result?.faces.first(where: { $0.id == selected }) else { return nil }
        var geometry = detected.geometry; geometry.excluded = excluded
        return AnalyzedFace(id: detected.id, box: detected.box, points: detected.points,
                            rating: FaceRatingEngine.evaluate(geometry), quality: detected.quality, geometry: geometry, mesh: detected.mesh)
    }
    func exclude(_ feature: String, _ value: Bool) {
        if value { excluded.insert(feature) } else { excluded.remove(feature) }
        status = face?.rating.reason ?? "Разбор обновлён по отмеченным зонам"
    }

    func resetExclusions() {
        excluded = []
        status = face?.rating.reason ?? "Разбор обновлён по доступным зонам"
    }

    func stop() {
        let wasActive = watching || busy
        token = UUID(); task?.cancel(); task = nil; selector.cancel(); watching = false; busy = false
        matchToken = UUID(); matchTask?.cancel(); matchTask = nil; matching = false
        if wasActive { status = "Анализ остановлен" }
    }

    func openPhoto() {
        stop()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let current = token; busy = true; result = nil; selected = nil; match = nil; status = "Разбираю фото…"
        task = Task {
            do {
                let analysis = try await Task.detached(priority: .userInitiated) {
                    try LocalFaceAnalyzer.analyze(LocalFaceAnalyzer.load(url))
                }.value
                guard token == current, !Task.isCancelled else { return }
                apply(analysis); busy = false; task = nil
            } catch {
                guard token == current else { return }
                busy = false; status = error.localizedDescription; task = nil
            }
        }
    }

    func chooseRegion(immediate: Bool = false) {
        stop(); busy = true
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        for window in NSApp.windows where window.level == .normal && window.isVisible { window.orderOut(nil) }
        let current = token
        task = Task {
            do {
                if !immediate {
                    for count in (1...3).reversed() {
                        status = "Открой нужное фото в любом приложении · \(count)"
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                guard token == current else { return }
                selector.select(point: false, title: "Обведи область фото для анализа") { [weak self] rect in
                    guard let self, self.token == current else { return }
                    self.busy = false; self.task = nil
                    guard let rect else { self.status = "Выбор области отменён"; return }
                    self.region = rect; self.result = nil; self.selected = nil; self.match = nil
                    self.status = "Область выбрана · наблюдаю за фрагментом экрана"
                    self.watch()
                }
            } catch { }
        }
    }

    func allowScreen() {
        _ = CGRequestScreenCaptureAccess()
        if !CGPreflightScreenCaptureAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        status = "Включи запись экрана для VoicePick. Если macOS попросит, перезапусти приложение."
    }

    func watch() {
        guard let region else { status = "Сначала выдели область фото"; return }
        guard canCapture() else { status = "Для наблюдения разреши запись экрана"; return }
        stop(); watching = true; result = nil; selected = nil; match = nil
        status = "Наблюдаю за выбранной областью экрана"
        let current = token
        task = Task {
            var committed: Fingerprint?
            var candidate: Fingerprint?
            var stable = 0
            while watching, token == current, !Task.isCancelled {
                do {
                    let image = try await capture(region)
                    try Task.checkCancellation()
                    guard token == current else { return }
                    let frame = try ScreenReader.fingerprint(image)
                    if committed.map({ frame.distance(to: $0) < 0.025 }) != true {
                        result = nil; selected = nil; match = nil
                        matchToken = UUID(); matchTask?.cancel(); matching = false
                        status = "Новая картинка · жду неподвижный кадр…"
                        if candidate.map({ frame.distance(to: $0) < 0.015 }) == true { stable += 1 }
                        else { candidate = frame; stable = 1 }
                        if stable >= 2 {
                            status = "Разбираю лицо…"
                            let analysis = try await analyze(image)
                            guard token == current, !Task.isCancelled else { return }
                            apply(analysis); committed = frame; candidate = nil; stable = 0
                        }
                    } else if let result {
                        status = result.faces.isEmpty ? "Лицо не найдено" : "Разбор текущего кадра готов"
                    }
                    try await Task.sleep(for: pollInterval)
                } catch is CancellationError { return }
                catch {
                    guard token == current else { return }
                    stop(); status = error.localizedDescription; return
                }
            }
        }
    }

    private func apply(_ analysis: FaceAnalysisResult) {
        result = analysis; excluded = []
        selected = analysis.faces.count == 1 ? analysis.faces.first?.id : nil
        if analysis.faces.isEmpty { status = "Лицо не найдено · числовой оценки нет" }
        else if analysis.faces.count > 1 { status = "Найдено лиц: \(analysis.faces.count) · выбери одно для разбора" }
        else { status = "Лицо найдено · разбор готов" }
        compare()
    }

    func selectFace(_ id: Int) {
        selected = id; excluded = []
        status = "Лицо выбрано · разбор готов"
        compare()
    }

    func compare() {
        matchToken = UUID(); matchTask?.cancel(); match = nil; matching = false
        guard let result, let face else { return }
        let current = matchToken
        let references = referenceStore.references.filter { $0.kind == kind }
        matching = true
        matchTask = Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try FaceReferenceVision.match(result.image, box: face.box, references: references)
                }.value
                guard matchToken == current, !Task.isCancelled else { return }
                match = value; matching = false; matchTask = nil
            } catch {
                guard matchToken == current else { return }
                matching = false; matchTask = nil; status = error.localizedDescription
            }
        }
    }

    func addReference() {
        guard !busy, !matching, let result, let face else { return }
        let current = token; let tier = referenceTier; let selectedKind = kind
        busy = true; status = "Сохраняю эталон…"
        task = Task {
            do {
                let reference = try await Task.detached(priority: .userInitiated) {
                    try FaceReferenceVision.make(result.image, box: face.box, tier: tier, kind: selectedKind, source: "Добавлен пользователем")
                }.value
                guard token == current, !Task.isCancelled else { return }
                try referenceStore.add(reference)
                busy = false; task = nil; status = "Эталон \(tier.rawValue) сохранён на Mac"
                compare()
            } catch {
                guard token == current else { return }
                busy = false; task = nil; status = error.localizedDescription
            }
        }
    }

    func saveReport() {
        guard let result, let face else { return }
        struct Report: Encodable {
            let version: String
            let method: String
            let width: Int
            let height: Int
            let faceBox: CGRect
            let landmarks: [CGPoint]
            let quality: Double?
            let rating: FaceRating
            let excluded: [String]
            let yaw: Double?
            let pitch: Double?
            let referenceKind: ReferenceKind
            let referenceMatch: ReferenceMatch?
            let mesh: FaceMesh?
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "face-debug.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = Report(version: "0.3", method: FaceReferenceBank.method, width: result.image.width,
                                height: result.image.height, faceBox: face.box, landmarks: face.points,
                                quality: face.quality, rating: face.rating, excluded: excluded.sorted(), yaw: face.geometry.yaw, pitch: face.geometry.pitch,
                                referenceKind: kind, referenceMatch: match, mesh: face.mesh)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
            status = "Разбор сохранён"
        } catch { status = error.localizedDescription }
    }
}

struct FaceDebugView: View {
    @ObservedObject var model: FaceDebugModel
    private let accent = Color(red: 0.64, green: 0.52, blue: 1)
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Анализ лица").font(.system(size: 25, weight: .bold))
                    Text("Сравнение с твоими эталонами на Mac")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.watching || model.busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("Открыть фото", systemImage: "photo") { model.openPhoto() }.disabled(model.busy)
                Button(model.region == nil ? "Выделить фото на экране" : "Выделить заново", systemImage: "viewfinder") { model.chooseRegion() }.disabled(model.busy)
                Spacer()
                if model.watching || model.busy { Button("Стоп") { model.stop(); model.status = "Наблюдение остановлено" } }
                else { Button("Наблюдать", systemImage: "eye") { model.watch() }.disabled(model.region == nil) }
            }.buttonStyle(.bordered)
            Text(model.status).font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
            Text("Область работает поверх любого приложения. После выделения наблюдение начнётся само. Для выбора без основного окна используй значок VoicePick в строке меню.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let result = model.result {
                Toggle("Показать карту лица", isOn: $model.showsLandmarks).toggleStyle(.switch)
                if let issue = result.meshIssue { Text(issue).font(.system(size: 12)).foregroundStyle(.orange) }
                FacePreview(result: result, selected: model.selected, showsLandmarks: model.showsLandmarks).frame(height: 300)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                if result.faces.count > 1 {
                    HStack {
                        Text("Разобрать:")
                        ForEach(result.faces) { face in
                            Button("Лицо \(face.id + 1)") { model.selectFace(face.id) }
                                .tint(model.selected == face.id ? accent : .gray)
                        }
                    }.buttonStyle(.bordered)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "face.smiling").font(.system(size: 42)).foregroundStyle(accent)
                    Text("Здесь появятся фото и разметка лица").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 210).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
            FaceReferencePanel(model: model, store: model.referenceStore)
            if let face = model.face {
                HStack {
                    Text(face.mesh == nil ? "Приблизительная разметка Vision · \(face.points.count) точек" : "Карта лица · \(face.points.count) точек · MediaPipe").foregroundStyle(.secondary)
                    Spacer()
                    Button("Сохранить разбор") { model.saveReport() }.buttonStyle(.bordered)
                }
                DisclosureGroup("Геометрия · диагностика") {
                    Text("Эти условные измерения не определяют категорию. Исключения ниже меняют только геометрический разбор.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(face.rating.explanation).font(.system(size: 12))
                    ForEach(face.rating.metrics) { metric in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title).fontWeight(.semibold)
                            Text(metric.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    ForEach(["leftEye", "rightEye", "nose", "lips", "contour"], id: \.self) { feature in
                        Toggle(["leftEye": "Исключить левый глаз", "rightEye": "Исключить правый глаз", "nose": "Исключить нос", "lips": "Исключить губы", "contour": "Исключить контур / подбородок"][feature]!,
                               isOn: Binding(get: { model.excluded.contains(feature) }, set: { model.exclude(feature,$0) }))
                    }
                }
            }
            DisclosureGroup("Как определяется категория") {
                Text("Сравнивается вырезанное лицо с локальной базой твоих меток. Ближайшие примеры показаны ниже результата. Рисунки и фотографии сравниваются в отдельных базах: выбери тип открытого изображения. Необязательно заполнять все семь категорий: сравниваются уже добавленные. При близком и однозначном совпадении показана выбранная категория. При слабом сходстве или небольшом отрыве показана ближайшая категория с пояснением.\n\nЭто экспериментальное сравнение изображений, не обученная модель привлекательности. Оно может учитывать причёску, ракурс, освещение и стиль рисунка. Даже выбранная категория может быть ошибочной. Добавляй разные реальные лица и проверяй на отдельных фото, которых нет в базе. Один рисунок на категорию не проверяет точность на фотографиях.\n\nФото обрабатывается на Mac. При добавлении эталона сохраняются признаки и миниатюра лица; исходный снимок не сохраняется. Этот режим только показывает разбор в приложении.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
            }
            HStack {
                Button("Разрешить экран") { model.allowScreen() }.buttonStyle(.bordered)
                Text("Нужно для анализа выбранной области экрана.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FaceReferencePanel: View {
    @ObservedObject var model: FaceDebugModel
    @ObservedObject var store: FaceReferenceStore
    private var references: [FaceReference] { store.references.filter { $0.kind == model.kind } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Тип изображения", selection: $model.kind) {
                ForEach(ReferenceKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).onChange(of: model.kind) { model.compare() }
                .disabled(model.busy)
            Text("Эталонов: \(references.count) · категории: \(Set(references.map(\.tier)).count) из 7")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let problem = store.problem { Text(problem).foregroundStyle(.orange) }
            if model.kind == .drawing {
                Text("Твоя таблица: по одному рисунку на категорию. Совпадение с самой таблицей проверяет работу сравнения, но не точность на новых лицах.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if references.isEmpty {
                Text("Для фото пока нет твоих эталонов. Открой фото, выбери лицо и свою категорию, затем добавь эталон. Для сравнения нужны хотя бы две разные категории.")
                    .font(.system(size: 13))
            }
            if model.matching { ProgressView("Сравниваю с эталонами…") }
            if let match = model.match {
                if !match.nearest.isEmpty {
                    Text(match.category == nil ? "Ближайшая категория" : "Категория")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(match.category?.rawValue ?? match.nearest.first?.tier.rawValue ?? "Нет эталонов")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(match.explanation).font(.system(size: 13))
                if !match.nearest.isEmpty {
                    Text("Ближайшие примеры").fontWeight(.semibold)
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(match.nearest) { neighbor in
                            if let reference = references.first(where: { $0.id == neighbor.id }) {
                                VStack(spacing: 5) {
                                    ReferenceThumbnail(reference: reference).frame(width: 100, height: 100)
                                    Text(reference.tier.rawValue).fontWeight(.semibold)
                                    Text(String(format: "Расстояние %.3f", neighbor.distance)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Меньше расстояние — ближе изображение. Это не балл внешности и не вероятность.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if model.face != nil {
                HStack {
                    Picker("Моя категория", selection: $model.referenceTier) {
                        ForEach(FaceTier.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth: 280)
                    Button("Добавить эталон") { model.addReference() }
                        .disabled(model.busy || model.matching || model.watching).buttonStyle(.bordered)
                }
                Text("Добавляется только выбранное лицо в базу «\(model.kind.title)» с твоей меткой.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            DisclosureGroup("Мои эталоны") {
                ForEach(FaceTier.allCases) { tier in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tier.rawValue).fontWeight(.semibold)
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(references.filter { $0.tier == tier }) { reference in
                                    VStack(spacing: 4) {
                                        ReferenceThumbnail(reference: reference).frame(width: 76, height: 76)
                                        Button("Удалить") { store.remove(reference.id); model.compare() }
                                            .disabled(model.busy || model.watching)
                                    }
                                }
                            }
                        }
                    }.padding(.top, 8)
                }
                if model.kind == .drawing && store.hasBundledDrawings {
                    Button("Восстановить рисунки из таблицы") { store.restoreDrawings(); model.compare() }
                        .disabled(model.busy || model.watching)
                }
            }
        }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ReferenceThumbnail: View {
    let reference: FaceReference
    var body: some View {
        if let image = NSImage(data: reference.thumbnail) {
            Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
        } else { Image(systemName: "photo") }
    }
}

private struct FacePreview: View {
    let result: FaceAnalysisResult
    let selected: Int?
    let showsLandmarks: Bool
    var body: some View {
        GeometryReader { geometry in
            let width = Double(result.image.width), height = Double(result.image.height)
            let scale = min(geometry.size.width / width, geometry.size.height / height)
            let offset = CGPoint(x: (geometry.size.width - width * scale) / 2,
                                 y: (geometry.size.height - height * scale) / 2)
            ZStack {
                Image(decorative: result.image, scale: 1)
                    .resizable().frame(width: width * scale, height: height * scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                Canvas { context, _ in
                    guard showsLandmarks else { return }
                    context.clip(to: Path(CGRect(x: offset.x, y: offset.y, width: width * scale, height: height * scale)))
                    for face in result.faces {
                        let color = face.mesh == nil ? Color.orange : (selected == face.id ? Color.mint : Color.purple)
                        let bounds = face.mesh?.bounds ?? face.box
                        let box = CGRect(x: offset.x + bounds.minX * scale, y: offset.y + (height - bounds.maxY) * scale,
                                         width: bounds.width * scale, height: bounds.height * scale)
                        context.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(color), lineWidth: 2)
                        context.draw(Text("\(face.id + 1)").font(.system(size: 12, weight: .bold)).foregroundColor(color),
                                     at: CGPoint(x: box.minX + 10, y: box.minY + 10))
                        func projected(_ point: CGPoint) -> CGPoint {
                            CGPoint(x: offset.x + point.x * scale, y: offset.y + (height - point.y) * scale)
                        }
                        if let mesh = face.mesh {
                            var path = Path()
                            for edge in mesh.edges {
                                path.move(to: projected(mesh.points[edge[0]])); path.addLine(to: projected(mesh.points[edge[1]]))
                            }
                            context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1)
                        }
                        // Highlight anatomical contours; dense interior points remain subtle.
                        let contourIndices = Set(face.mesh?.edges.flatMap { $0 } ?? [])
                        for (index, point) in face.points.enumerated() {
                            let radius = face.mesh == nil ? 1.5 : (contourIndices.contains(index) ? 1.2 : 0.6)
                            let rect = CGRect(x: offset.x + point.x * scale - radius,
                                              y: offset.y + (height - point.y) * scale - radius, width: radius * 2, height: radius * 2)
                            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(contourIndices.contains(index) || face.mesh == nil ? 0.8 : 0.25)))
                        }
                    }
                }
            }
        }
    }
}
