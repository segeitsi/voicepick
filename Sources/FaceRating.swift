import Foundation
import CoreGraphics

struct FaceMetric: Codable, Identifiable {
    let id: String
    let title: String
    let score: Double
    let weight: Double
    let detail: String
}

struct FaceRating: Codable {
    let score: Double?
    let metrics: [FaceMetric]
    let explanation: String
    let reason: String?
}

struct FaceGeometry {
    let width: Double
    let height: Double
    let leftEye: [CGPoint]
    let rightEye: [CGPoint]
    let nose: [CGPoint]
    let lips: [CGPoint]
    let contour: [CGPoint]
    let yaw: Double?
    let pitch: Double?
    let quality: Double?
    let confidence: Double
    var roll: Double? = nil
    var reliability: [String: Double] = [:]
    var excluded: Set<String> = []
}

/// Debug heuristics, not a model trained on attractiveness ratings.
/// All targets/tolerances and weights are documented in README.md.
enum FaceRatingEngine {
    static func evaluate(_ face: FaceGeometry) -> FaceRating {
        func unavailable(_ reason: String) -> FaceRating {
            FaceRating(score: nil, metrics: [], explanation: reason, reason: reason)
        }
        guard face.width.isFinite, face.height.isFinite, min(face.width, face.height) >= 35, max(face.width, face.height) >= 90 else {
            return unavailable("Лицо слишком маленькое. Выбери фото покрупнее.")
        }
        guard face.confidence.isFinite, face.confidence >= 0.3 else {
            return unavailable("Лицо видно недостаточно чётко для разбора.")
        }
        guard let yaw = face.yaw, let pitch = face.pitch else {
            return unavailable("Не удалось определить ракурс лица. Попробуй другое фото.")
        }
        guard yaw.isFinite, pitch.isFinite, abs(pitch) <= 45 else {
            return unavailable("Слишком сильный наклон вверх/вниз для устойчивого разбора.")
        }
        if min(face.width, face.height) < 90 || abs(yaw) > 20 || abs(pitch) > 18 || !face.excluded.isEmpty ||
            face.leftEye.count < 4 || face.rightEye.count < 4 || face.contour.count < 9 || face.nose.isEmpty || face.lips.isEmpty ||
            (face.quality.map { $0 < 0.1 } ?? false) {
            return partial(face)
        }
        let sets = [face.leftEye, face.rightEye, face.nose, face.lips, face.contour]
        guard sets.allSatisfy({ $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }),
              face.leftEye.count >= 4, face.rightEye.count >= 4,
              !face.nose.isEmpty, !face.lips.isEmpty, face.contour.count >= 9 else {
            return unavailable("Не удалось уверенно отметить глаза, нос, рот и контур лица.")
        }
        func mean(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                    y: points.map(\.y).reduce(0, +) / Double(points.count))
        }
        var a = face.leftEye, b = face.rightEye
        if mean(a).x > mean(b).x { swap(&a, &b) }
        let centerA = mean(a), centerB = mean(b)
        let origin = CGPoint(x: (centerA.x + centerB.x) / 2, y: (centerA.y + centerB.y) / 2)
        let angle = atan2(centerB.y - centerA.y, centerB.x - centerA.x)
        func level(_ p: CGPoint) -> CGPoint {
            let x = p.x - origin.x, y = p.y - origin.y
            return CGPoint(x: x * cos(angle) + y * sin(angle), y: -x * sin(angle) + y * cos(angle))
        }
        a = a.map(level); b = b.map(level)
        let nose = mean(face.nose.map(level)), lips = mean(face.lips.map(level))
        let contour = face.contour.map(level)
        let width = (contour.map(\.x).max() ?? 0) - (contour.map(\.x).min() ?? 0)
        let eyeDistance = abs(mean(b).x - mean(a).x)
        guard width > 20, eyeDistance > 10, lips.y < 0 else {
            return unavailable("Разметка лица нестабильна. Попробуй более чёткое фото анфас.")
        }
        func span(_ points: [CGPoint]) -> Double { (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0) }
        func similarity(_ error: Double, tolerance: Double) -> Double {
            min(1, max(0, 1 - abs(error) / tolerance))
        }
        func score(_ value: Double) -> Double { (1 + 9 * min(1, max(0, value))) }
        func format(_ value: Double) -> String { String(format: "%.2f", value) }
        let eyeWidthBalance = min(span(a), span(b)) / max(0.001, max(span(a), span(b)))
        let midlineError = (abs(nose.x) + abs(lips.x)) / (2 * width)
        let contourError = contour.map { point in
            contour.map { hypot($0.x + point.x, $0.y - point.y) }.min() ?? width
        }.reduce(0, +) / Double(contour.count) / width
        let symmetry = score((similarity(midlineError, tolerance: 0.08) +
                              similarity(contourError, tolerance: 0.1) + eyeWidthBalance) / 3)
        let eyeRatio = eyeDistance / width
        let midfaceRatio = abs(lips.y) / face.height
        let proportions = score((similarity(eyeRatio - 0.46, tolerance: 0.20) +
                                 similarity(midfaceRatio - 0.36, tolerance: 0.18)) / 2)
        func tilt(_ points: [CGPoint], left: Bool) -> Double {
            let first = points.min(by: { $0.x < $1.x })!, last = points.max(by: { $0.x < $1.x })!
            let rise = left ? first.y - last.y : last.y - first.y
            return atan2(rise, max(0.001, last.x - first.x)) * 180 / .pi
        }
        let tiltA = tilt(a, left: true), tiltB = tilt(b, left: false)
        let averageTilt = (tiltA + tiltB) / 2
        let eyes = score((similarity(averageTilt - 4, tolerance: 14) + eyeWidthBalance) / 2)
        let chin = contour.map(\.y).min() ?? 0
        let jawLevel = chin * 0.6
        var intersections: [Double] = []
        for (p, q) in zip(contour, contour.dropFirst()) {
            if (p.y <= jawLevel && q.y >= jawLevel) || (q.y <= jawLevel && p.y >= jawLevel), abs(q.y - p.y) > 0.001 {
                let fraction = (jawLevel - p.y) / (q.y - p.y)
                intersections.append(p.x + fraction * (q.x - p.x))
            }
        }
        guard intersections.count >= 2 else { return unavailable("Нижний контур лица закрыт или не размечен.") }
        let jawRatio = (intersections.max()! - intersections.min()!) / width
        let jaw = score(similarity(jawRatio - 0.75, tolerance: 0.30))
        let metrics = [
            FaceMetric(id: "symmetry", title: "Симметрия", score: symmetry, weight: 0.30,
                       detail: "Смещение носа и рта: \(format(midlineError * 100))% ширины лица. Расхождение контура: \(format(contourError * 100))%."),
            FaceMetric(id: "proportions", title: "Пропорции", score: proportions, weight: 0.30,
                       detail: "Расстояние между глазами / ширина: \(format(eyeRatio)); ориентир 0,46. Глаза–рот / высота: \(format(midfaceRatio)); ориентир 0,36."),
            FaceMetric(id: "eyes", title: "Область глаз", score: eyes, weight: 0.20,
                       detail: "Наклон внешних уголков: \(format(averageTilt))°. Совпадение ширины глаз: \(format(eyeWidthBalance * 100))%."),
            FaceMetric(id: "jaw", title: "Контур челюсти", score: jaw, weight: 0.20,
                       detail: "Ширина нижнего контура / ширина лица: \(format(jawRatio)); ориентир 0,75.")
        ]
        let overall = (metrics.reduce(0) { $0 + $1.score * $1.weight } * 10).rounded() / 10
        let sorted = metrics.sorted { $0.score > $1.score }
        let explanation = "Предварительная оценка по отладочной шкале: \(String(format: "%.1f", overall))/10. Наибольший балл — \(sorted.first!.title.lowercased()), наименьший — \(sorted.last!.title.lowercased())."
        return FaceRating(score: overall, metrics: metrics, explanation: explanation, reason: nil)
    }

    /// No frontal symmetry/width comparison on perspective-distorted or missing regions.
    private static func partial(_ face: FaceGeometry) -> FaceRating {
        var metrics: [FaceMetric] = []
        var omitted: [String] = []
        func usable(_ name: String, _ points: [CGPoint], minimum: Int) -> Bool {
            !face.excluded.contains(name) && points.count >= minimum &&
            points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
        func mean(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0,+) / Double(points.count), y: points.map(\.y).reduce(0,+) / Double(points.count))
        }
        func span(_ points: [CGPoint]) -> Double { (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0) }
        func score(_ error: Double, _ tolerance: Double) -> Double { 1 + 9 * min(1, max(0, 1 - abs(error) / tolerance)) }
        func format(_ value: Double) -> String { String(format: "%.2f", value) }
        let leftOK = usable("leftEye", face.leftEye, minimum: 4), rightOK = usable("rightEye", face.rightEye, minimum: 4)
        let noseOK = usable("nose", face.nose, minimum: 2), lipsOK = usable("lips", face.lips, minimum: 3)
        let contourOK = usable("contour", face.contour, minimum: 5)
        let profile = abs(face.yaw ?? 0) > 55
        let bothEyes = leftOK && rightOK && !profile
        let eyePoints = bothEyes ? face.leftEye + face.rightEye :
            (leftOK && (!rightOK || span(face.leftEye) >= span(face.rightEye)) ? face.leftEye : rightOK ? face.rightEye : [])
        let angle: Double
        if bothEyes {
            var a = mean(face.leftEye), b = mean(face.rightEye)
            if a.x > b.x { swap(&a,&b) }
            angle = atan2(b.y - a.y, b.x - a.x)
        } else { angle = (face.roll ?? 0) * .pi / 180 }
        func level(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * cos(angle) + p.y * sin(angle), y: -p.x * sin(angle) + p.y * cos(angle)) }
        let eyes = eyePoints.map(level), lips = lipsOK ? mean(face.lips.map(level)) : nil
        let contour = contourOK ? face.contour.map(level) : []
        let chin = contour.min { $0.y < $1.y }
        omitted.append("Симметрия: пропущена из-за ракурса или неполной разметки.")
        if !eyes.isEmpty, let lips, let chin {
            let eye = mean(eyes), height = eye.y - chin.y
            let lower = lips.y - chin.y
            if height > 25, lower > 0, lower < height {
                let ratio = lower / height
                metrics.append(FaceMetric(id: "vertical", title: "Вертикальные пропорции", score: score(ratio - 0.33, 0.20), weight: 0.30,
                    detail: "Рот–подбородок / глаза–подбородок: \(format(ratio)); условный ориентир 0,33. Ширина лица при повороте не сравнивается."))
            }
        }
        if !metrics.contains(where: { $0.id == "vertical" }) { omitted.append("Пропорции: нужны глаз, губы и подбородок.") }
        if !profile, !eyes.isEmpty {
            var tilts: [Double] = []
            for points in [leftOK ? face.leftEye : [], rightOK ? face.rightEye : []] where !points.isEmpty {
                let points = points.map(level)
                guard let first = points.min(by: { $0.x < $1.x }), let last = points.max(by: { $0.x < $1.x }), last.x - first.x > 3 else { continue }
                let outwardLeft = mean(points).x < mean(eyes).x || !rightOK
                tilts.append(atan2(outwardLeft ? first.y - last.y : last.y - first.y, last.x - first.x) * 180 / .pi)
            }
            if !tilts.isEmpty {
                let tilt = tilts.reduce(0,+) / Double(tilts.count)
                metrics.append(FaceMetric(id: "eyes", title: "Область глаз · частично", score: score(tilt - 4, 14), weight: 0.20,
                    detail: "Наклон размеченных уголков: \(format(tilt))°. Размер дальнего глаза и баланс глаз при повороте не оцениваются."))
            }
        }
        if !metrics.contains(where: { $0.id == "eyes" }) { omitted.append("Глаза: сравнение уголков в профиль или без надёжных точек пропущено.") }
        if profile, noseOK, let lips, let chin {
            let nosePoints = face.nose.map(level)
            if let tip = nosePoints.max(by: { abs($0.x - lips.x) < abs($1.x - lips.x) }) {
                let a = CGPoint(x: tip.x - lips.x, y: tip.y - lips.y), b = CGPoint(x: chin.x - lips.x, y: chin.y - lips.y)
                let length = hypot(a.x,a.y) * hypot(b.x,b.y)
                if length > 25 {
                    let angle = acos(min(1,max(-1,(a.x*b.x+a.y*b.y)/length))) * 180 / .pi
                    metrics.append(FaceMetric(id: "profile", title: "Линия профиля · приближение", score: score(angle - 165, 35), weight: 0.20,
                        detail: "Угол нос–губы–подбородок: \(format(angle))°; отладочный ориентир 165°. Это оценка по разметке, без восстановления скрытой стороны."))
                }
            }
        }
        if !metrics.contains(where: { $0.id == "profile" }) { omitted.append("Челюсть: фронтальная ширина при повороте/закрытии не оценивается.") }
        let weight = metrics.reduce(0) { $0 + $1.weight }
        let normalized = metrics.map { FaceMetric(id: $0.id,title: $0.title,score: $0.score,weight: $0.weight / max(weight,0.001),detail: $0.detail) }
        // One surviving measurement is still useful, but is not an overall face rating.
        let overall = metrics.count >= 2 ? (metrics.reduce(0) { $0 + $1.score * $1.weight } / weight * 10).rounded() / 10 : nil
        let pose = profile ? "Профиль" : abs(face.yaw ?? 0) > 20 ? "Ракурс 3/4" : "Неполная разметка"
        let title = overall.map { "\(pose) · частичная оценка \(String(format: "%.1f",$0))/10 по \(metrics.count) критериям." } ??
            "\(pose) · доступно критериев: \(metrics.count). Для общего балла нужны хотя бы два."
        let explanation = title + " Балл не сопоставим напрямую с полной оценкой анфас.\n" + omitted.joined(separator: "\n") +
            "\nВолосы и предметы могут мешать разметке. Если точки попали на закрытую область, исключи её ниже."
        return FaceRating(score: overall,metrics: normalized,explanation: explanation,reason: overall == nil ? title : nil)
    }

}
