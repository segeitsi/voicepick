import Foundation

@main
struct FaceReferenceTests {
    @MainActor static func main() throws {
        let ids = FaceTier.allCases.map { _ in UUID() }
        func neighbors(_ values: [Double]) -> [ReferenceNeighbor] {
            zip(zip(ids, FaceTier.allCases), values).map { ReferenceNeighbor(id: $0.0.0, tier: $0.0.1, distance: $0.1) }
        }
        let spacing = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.8) })
        func check(_ valid: Bool, _ name: String) { guard valid else { fatalError(name) }; print("PASS: \(name)") }
        let empty = ReferenceDecision.evaluate(neighbors: [], separation: [:])
        check(empty.category == nil && empty.missing.count == 7, "No references cannot yield a category")
        let incomplete = ReferenceDecision.evaluate(neighbors: Array(neighbors([0,1,1,1,1,1,1]).prefix(1)), separation: spacing)
        check(incomplete.category == nil && incomplete.missing.count == 6 && incomplete.nearest.first?.tier == .sub3,
              "One category retains nearest sample but cannot distinguish alternatives")
        let six = ReferenceDecision.evaluate(neighbors: neighbors([0.9,0.8,0.7,0.6,0.1,0.8]), separation: spacing)
        check(six.category == .htb && six.missing == [.trueEve], "HTB is selected with six categories even when true eve is absent")
        let two = ReferenceDecision.evaluate(neighbors: Array(neighbors([0.1,0.8]).prefix(2)), separation: spacing)
        check(two.category == .sub3 && two.missing.count == 5, "Two well-separated categories are enough for classification")
        let partialFar = ReferenceDecision.evaluate(neighbors: Array(neighbors([0.7,0.8,0.9]).prefix(3)), separation: spacing)
        check(partialFar.category == nil && partialFar.nearest.first?.tier == .sub3 && partialFar.missing.count == 4,
              "Incomplete bank still reports weak similarity without hiding nearest category")
        let partialTie = ReferenceDecision.evaluate(neighbors: Array(neighbors([0.3,0.31]).prefix(2)), separation: spacing)
        check(partialTie.category == nil && partialTie.nearest.count == 2 && partialTie.missing.count == 5,
              "Incomplete bank still distinguishes an ambiguous match")
        let matchRoundtrip = try JSONDecoder().decode(ReferenceMatch.self, from: JSONEncoder().encode(six))
        check(matchRoundtrip.category == .htb && matchRoundtrip.missing == [.trueEve], "Selected category and missing coverage survive report roundtrip")
        let near = ReferenceDecision.evaluate(neighbors: neighbors([0.1,0.8,0.9,1,1.1,1.2,1.3]), separation: spacing)
        check(near.category == .sub3 && near.nearest.count == 3, "Close unambiguous sample follows the user's label")
        let reversed = neighbors([0.1,0.8,0.9,1,1.1,1.2,1.3]).enumerated().map {
            ReferenceNeighbor(id: $0.element.id, tier: FaceTier.allCases.reversed()[$0.offset], distance: $0.element.distance)
        }
        check(ReferenceDecision.evaluate(neighbors: reversed, separation: spacing).category == .trueEve, "Relabelling samples changes categories without geometry rules")
        let far = ReferenceDecision.evaluate(neighbors: neighbors([0.7,0.8,0.9,1,1.1,1.2,1.3]), separation: spacing)
        check(far.category == nil && far.nearest.first?.tier == .sub3, "Distant samples show nearest examples but withhold category")
        let ambiguous = ReferenceDecision.evaluate(neighbors: neighbors([0.3,0.31,0.9,1,1.1,1.2,1.3]), separation: spacing)
        check(ambiguous.category == nil, "Ambiguous categories are withheld")
        let duplicate = ReferenceDecision.evaluate(neighbors: neighbors([0,0,0.9,1,1.1,1.2,1.3]), separation: Dictionary(uniqueKeysWithValues: ids.map { ($0,0.0) }))
        check(duplicate.category == nil, "Conflicting duplicate images cannot yield a category")
        let invalid = ReferenceDecision.evaluate(neighbors: neighbors([.nan,0.1,0.9,1,1.1,1.2,1.3]), separation: spacing)
        check(invalid.category == .sub5 && invalid.missing == [.sub3], "Invalid distances are excluded while remaining valid categories can match")
        let extra = ReferenceNeighbor(id: UUID(), tier: .sub3, distance: 0.12)
        let many = ReferenceDecision.evaluate(neighbors: neighbors([0.1,0.8,0.9,1,1.1,1.2,1.3]) + [extra], separation: spacing)
        check(many.nearest.map(\.tier) == [.sub3,.sub5,.ltb], "Repeated samples do not hide competing categories")
        let bank = FaceReferenceBank(version: 1, method: FaceReferenceBank.method, references: [
            FaceReference(id: ids[0], tier: .sub3, kind: .photo, source: "test", thumbnail: Data([1,2]), feature: Data([3,4]))
        ])
        let url = URL(fileURLWithPath: "build/tests/reference-roundtrip.json")
        try JSONEncoder().encode(bank).write(to: url)
        let loaded = try FaceReferenceBank.read(url)
        check(loaded.references[0].feature == Data([3,4]) && loaded.references[0].kind == .photo && loaded.references[0].tier == .sub3, "Reference labels, domain and binary data survive JSON roundtrip")
        try FileManager.default.removeItem(at: url)
        let seed = URL(fileURLWithPath: "build/tests/reference-seed.json")
        try JSONEncoder().encode(bank).write(to: seed)
        defer { try? FileManager.default.removeItem(at: seed); try? FileManager.default.removeItem(at: url) }
        let store = FaceReferenceStore(storageURL: url, seedURL: seed)
        check(store.references.count == 1, "New database loads bundled samples")
        let added = FaceReference(id: UUID(), tier: .mtb, kind: .drawing, source: "user", thumbnail: Data([5]), feature: Data([6]))
        try store.add(added)
        let restarted = FaceReferenceStore(storageURL: url, seedURL: seed)
        check(restarted.references.count == 2 && restarted.references.last?.tier == .mtb, "Added user labels survive database restart")
        restarted.remove(added.id)
        let afterRemoval = FaceReferenceStore(storageURL: url, seedURL: seed)
        check(afterRemoval.references.count == 1 && afterRemoval.references[0].id == ids[0], "Removing a reference persists without deleting other samples")
    }
}
