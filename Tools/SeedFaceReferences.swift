import AppKit

@main
struct SeedFaceReferences {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: seed-references chart.png output.json") }
        let image = try LocalFaceAnalyzer.load(URL(fileURLWithPath: CommandLine.arguments[1]))
        let analysis = try LocalFaceAnalyzer.analyze(image)
        guard analysis.faces.count == 7 else { fatalError("Expected exactly seven faces in the supplied tier chart") }
        // Manual annotation of this specific chart only. Prediction never uses face position.
        let byRows = analysis.faces.sorted { $0.box.midY > $1.box.midY }
        let ordered = Array(byRows.prefix(3)).sorted { $0.box.midX < $1.box.midX } +
            Array(byRows.dropFirst(3).prefix(3)).sorted { $0.box.midX < $1.box.midX } + Array(byRows.suffix(1))
        let references = try zip(ordered, FaceTier.allCases).map { face, tier in
            print("Label \(tier.rawValue): center \(Int(face.box.midX)),\(Int(face.box.midY))")
            return try FaceReferenceVision.make(image, box: face.box, tier: tier, kind: .drawing, source: "Таблица пользователя")
        }
        let bank = FaceReferenceBank(version: 1, method: FaceReferenceBank.method, references: references)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(bank).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print("Saved seven labelled drawing references")
    }
}
