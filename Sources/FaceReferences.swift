import Foundation
import AppKit
import Vision

enum FaceTier: String, Codable, CaseIterable, Identifiable {
    case sub3 = "sub 3", sub5 = "sub 5", ltb = "LTB", mtb = "MTB", htb = "HTB", stacy = "stacy", trueEve = "true eve"
    var id: String { rawValue }
}

enum ReferenceKind: String, Codable, CaseIterable, Identifiable {
    case photo, drawing
    var id: String { rawValue }
    var title: String { self == .photo ? "Фотографии" : "Рисунки" }
}

struct FaceReference: Codable, Identifiable {
    let id: UUID
    let tier: FaceTier
    let kind: ReferenceKind
    let source: String
    let thumbnail: Data
    let feature: Data
}

struct FaceReferenceBank: Codable {
    let version: Int
    let method: String
    var references: [FaceReference]
    static let method = "vision-image-feature-print-r2-face-crop-v1"
    static func read(_ url: URL) throws -> FaceReferenceBank {
        let bank = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard bank.version == 1, bank.method == method else {
            throw ReferenceError.message("Формат эталонов несовместим с этой версией приложения")
        }
        return bank
    }
}

enum ReferenceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct ReferenceNeighbor: Codable, Identifiable {
    let id: UUID
    let tier: FaceTier
    let distance: Double
}

struct ReferenceMatch: Codable {
    let category: FaceTier?
    let nearest: [ReferenceNeighbor]
    let explanation: String
    let missing: [FaceTier]
}

// Distances are visual similarity, not an attractiveness score or a probability.
enum ReferenceDecision {
    static func evaluate(neighbors: [ReferenceNeighbor], separation: [UUID: Double]) -> ReferenceMatch {
        let valid = neighbors.filter { $0.distance.isFinite && $0.distance >= 0 }.sorted { $0.distance < $1.distance }
        let covered = Set(valid.map(\.tier))
        let missing = FaceTier.allCases.filter { !covered.contains($0) }
        var seen = Set<FaceTier>()
        let alternatives = valid.filter { seen.insert($0.tier).inserted }
        let shown = Array(alternatives.prefix(3))
        guard let best = valid.first else {
            return ReferenceMatch(category: nil, nearest: [], explanation: "В этой базе пока нет пригодных эталонов. Добавь фото с твоими категориями.", missing: missing)
        }
        guard alternatives.count >= 2 else {
            return ReferenceMatch(category: nil, nearest: shown, explanation: "В базе пока только категория \(best.tier.rawValue). Добавь хотя бы одну другую категорию для сравнения.", missing: missing)
        }
        guard let second = alternatives.dropFirst().first, let spacing = separation[best.id], spacing.isFinite, spacing > 0.0001 else {
            return ReferenceMatch(category: nil, nearest: shown, explanation: "Эталоны разных категорий слишком похожи или несовместимы. Проверь метки в базе.", missing: missing)
        }
        // Conservative abstention: neighborhood smaller than half the nearest inter-class distance.
        guard best.distance <= spacing * 0.5 else {
            return ReferenceMatch(category: nil, nearest: shown, explanation: "Ближе всего \(best.tier.rawValue), но сходство с эталоном слабое. Добавь похожие фото с твоими метками.", missing: missing)
        }
        guard second.distance - best.distance > max(0.015, second.distance * 0.08) else {
            return ReferenceMatch(category: nil, nearest: shown, explanation: "\(best.tier.rawValue) и \(second.tier.rawValue) дают близкое совпадение. Показан ближайший вариант, но между ними небольшой отрыв.", missing: missing)
        }
        return ReferenceMatch(category: best.tier, nearest: shown, explanation: "Совпадение с эталоном \(best.tier.rawValue). Сравнение среди \(covered.count) добавленных категорий.", missing: missing)
    }
}

enum FaceReferenceVision {
    static func crop(_ image: CGImage, box: CGRect) throws -> CGImage {
        guard !box.isEmpty, box.width.isFinite, box.height.isFinite else { throw ReferenceError.message("Не удалось вырезать лицо") }
        let side = max(box.width, box.height) * 1.24
        // Vision uses a bottom-left origin; CGImage cropping uses top-left pixels.
        let rect = CGRect(x: box.midX - side / 2, y: Double(image.height) - box.midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard rect.width >= 35, rect.height >= 35, let cropped = image.cropping(to: rect) else {
            throw ReferenceError.message("Лицо слишком маленькое для сравнения")
        }
        return cropped
    }

    static func feature(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .centerCrop
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        guard let result = request.results?.first else { throw ReferenceError.message("Не удалось получить признаки лица") }
        return result
    }

    static func decode(_ data: Data) throws -> VNFeaturePrintObservation {
        guard let print = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data),
              print.requestRevision == VNGenerateImageFeaturePrintRequestRevision2 else {
            throw ReferenceError.message("Эталон несовместим с текущим распознаванием. Добавь его заново.")
        }
        return print
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) throws -> Double {
        var distance: Float = 0
        try a.computeDistance(&distance, to: b)
        guard distance.isFinite, distance >= 0 else { throw ReferenceError.message("Некорректное расстояние до эталона") }
        return Double(distance)
    }

    static func make(_ image: CGImage, box: CGRect, tier: FaceTier, kind: ReferenceKind, source: String) throws -> FaceReference {
        let cropped = try crop(image, box: box)
        let print = try feature(cropped)
        let size = CGSize(width: 144, height: 144)
        let context = CGContext(data: nil, width: 144, height: 144, bitsPerComponent: 8, bytesPerRow: 144 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(origin: .zero, size: size))
        guard let thumbnail = context.makeImage(), let jpeg = NSBitmapImageRep(cgImage: thumbnail).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw ReferenceError.message("Не удалось сохранить миниатюру")
        }
        return FaceReference(id: UUID(), tier: tier, kind: kind, source: source, thumbnail: jpeg,
                             feature: try NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true))
    }

    static func match(_ image: CGImage, box: CGRect, references: [FaceReference]) throws -> ReferenceMatch {
        guard !references.isEmpty else { return ReferenceDecision.evaluate(neighbors: [], separation: [:]) }
        let query = try feature(crop(image, box: box))
        let decoded = try references.map { ($0, try decode($0.feature)) }
        let neighbors = try decoded.map { ReferenceNeighbor(id: $0.0.id, tier: $0.0.tier, distance: try distance(query, $0.1)) }
        var separation: [UUID: Double] = [:]
        for (reference, print) in decoded {
            let different = try decoded.filter { $0.0.tier != reference.tier }.map { try distance(print, $0.1) }
            separation[reference.id] = different.min()
        }
        return ReferenceDecision.evaluate(neighbors: neighbors, separation: separation)
    }
}

@MainActor
final class FaceReferenceStore: ObservableObject {
    @Published private(set) var references: [FaceReference] = []
    @Published private(set) var problem: String?
    private let url: URL
    private let seedURL: URL?
    var hasBundledDrawings: Bool { seedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    init(storageURL: URL? = nil, seedURL: URL? = nil) {
        url = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ББ ДВ", isDirectory: true).appendingPathComponent("reference-bank-v1.json")
        self.seedURL = seedURL ?? Bundle.main.url(forResource: "drawing-references", withExtension: "json")
        do {
            if FileManager.default.fileExists(atPath: url.path) { references = try FaceReferenceBank.read(url).references }
            else if let seed = self.seedURL {
                references = try FaceReferenceBank.read(seed).references
            }
        } catch { problem = error.localizedDescription }
    }
    func add(_ reference: FaceReference) throws {
        let updated = references + [reference]
        try save(updated); references = updated; problem = nil
    }
    func remove(_ id: UUID) {
        do { let updated = references.filter { $0.id != id }; try save(updated); references = updated; problem = nil }
        catch { problem = error.localizedDescription }
    }
    func restoreDrawings() {
        do {
            guard let seed = seedURL else { throw ReferenceError.message("Встроенная таблица не найдена") }
            let originals = try FaceReferenceBank.read(seed).references
            let updated = references.filter { $0.source != "Таблица пользователя" } + originals
            try save(updated); references = updated; problem = nil
        } catch { problem = error.localizedDescription }
    }
    private func save(_ references: [FaceReference]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bank = FaceReferenceBank(version: 1, method: FaceReferenceBank.method, references: references)
        try JSONEncoder().encode(bank).write(to: url, options: .atomic)
    }
}
