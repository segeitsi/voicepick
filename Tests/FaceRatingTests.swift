import Foundation
import CoreGraphics

@main
struct FaceRatingTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ text: String) {
            count += 1; guard condition() else { fatalError("FAILED: " + text) }
        }
        func eye(_ x: Double, left: Bool) -> [CGPoint] {
            let rise = tan(4 * Double.pi / 180) * 12
            return [CGPoint(x: x - 12, y: 55 + (left ? rise : -rise)),
                    CGPoint(x: x, y: 61), CGPoint(x: x + 12, y: 55 + (left ? -rise : rise)),
                    CGPoint(x: x, y: 49)]
        }
        let contour: [CGPoint] = [(-100.0,55.0),(-98,20),(-87,-15),(-75,-44),(-55,-75),(-25,-103),(0,-110),
                                   (25,-103),(55,-75),(75,-44),(87,-15),(98,20),(100,55)].map { CGPoint(x: $0.0, y: $0.1) }
        func face(width: Double = 200, height: Double = 240, yaw: Double? = 0, pitch: Double? = 0,
                  quality: Double? = 0.7, confidence: Double = 0.9, shift: Double = 0,
                  transform: (CGPoint) -> CGPoint = { $0 }) -> FaceGeometry {
            FaceGeometry(width: width, height: height, leftEye: eye(-46, left: true).map(transform),
                         rightEye: eye(46, left: false).map(transform),
                         nose: [CGPoint(x: shift - 0.1, y: 8), CGPoint(x: shift + 0.1, y: 8)].map(transform), lips: [CGPoint(x: shift - 0.1, y: -31.4), CGPoint(x: shift, y: -31.4), CGPoint(x: shift + 0.1, y: -31.4)].map(transform),
                         contour: contour.map(transform), yaw: yaw, pitch: pitch, quality: quality, confidence: confidence)
        }
        let reference = FaceRatingEngine.evaluate(face())
        check(reference.score != nil, "valid frontal landmarks produce a score")
        check(reference.metrics.count == 4, "all four criteria are explained")
        check(abs(reference.metrics.reduce(0) { $0 + $1.weight } - 1) < 0.000001, "weights sum to one")
        check(reference.metrics.allSatisfy { (1...10).contains($0.score) }, "component scores are bounded")
        check(reference.score == 10, "chosen heuristic reference reaches its reference score")
        check(FaceRatingEngine.evaluate(face(yaw: 35)).score != nil, "3/4 has a partial score")
        check(FaceRatingEngine.evaluate(face(pitch: 30)).score != nil, "moderate pitch uses partial geometry")
        check(FaceRatingEngine.evaluate(face(yaw: nil)).score == nil, "unknown pose withheld")
        check(FaceRatingEngine.evaluate(face(width: 25)).score == nil, "small face withheld")
        check(FaceRatingEngine.evaluate(face(quality: 0.01)).metrics.isEmpty, "poor capture quality suppresses measurements")
        check(FaceRatingEngine.evaluate(face(confidence: 0.1)).score == nil, "poor landmarks withheld")
        check(FaceRatingEngine.evaluate(face(quality: nil)).score != nil, "unavailable quality estimate does not invent a quality penalty")
        let shifted = FaceRatingEngine.evaluate(face(shift: 18))
        check(shifted.metrics.first!.score < reference.metrics.first!.score, "midline asymmetry changes the symmetry component")
        let translated = FaceRatingEngine.evaluate(face(transform: { CGPoint(x: $0.x + 900, y: $0.y + 300) }))
        check(translated.score == reference.score, "image translation does not change rating")
        let scaled = FaceRatingEngine.evaluate(face(width: 400, height: 480, transform: { CGPoint(x: $0.x * 2, y: $0.y * 2) }))
        check(scaled.score == reference.score, "image scale does not change rating")
        let angle = 12 * Double.pi / 180
        let rotated = FaceRatingEngine.evaluate(face(transform: { CGPoint(x: $0.x * cos(angle) - $0.y * sin(angle), y: $0.x * sin(angle) + $0.y * cos(angle)) }))
        check(rotated.score == reference.score, "moderate roll is compensated")
        check(FaceRatingEngine.evaluate(face(transform: { _ in .zero })).score == nil, "collapsed landmarks withheld")
        check(FaceRatingEngine.evaluate(face(transform: { _ in CGPoint(x: Double.nan, y: 0) })).score == nil, "nonfinite landmarks withheld")
        for shift in stride(from: -80.0, through: 80, by: 4) {
            let report = FaceRatingEngine.evaluate(face(shift: shift))
            check(report.score.map { (1...10).contains($0) && $0.isFinite } == true, "rating finite and bounded for asymmetry")
        }
        let threeQuarter = FaceRatingEngine.evaluate(face(yaw: 40))
        check(!threeQuarter.metrics.contains { $0.id == "symmetry" }, "yaw is not mistaken for asymmetry")
        check(!threeQuarter.metrics.contains { $0.id == "jaw" }, "frontal jaw width not used at 3/4")
        check(abs(threeQuarter.metrics.reduce(0) { $0 + $1.weight } - 1) < 0.000001, "partial weights renormalized")
        var occluded = face(); occluded.excluded = ["leftEye"]
        check(FaceRatingEngine.evaluate(occluded).score != nil, "one excluded eye leaves useful partial score")
        occluded.excluded = ["leftEye", "rightEye"]
        check(FaceRatingEngine.evaluate(occluded).score == nil, "no eye anchor means no invented overall rating")
        occluded.excluded = ["contour"]
        let oneMetric = FaceRatingEngine.evaluate(occluded)
        check(oneMetric.score == nil && oneMetric.metrics.isEmpty, "missing contour suppresses measurements")
        check(FaceRatingEngine.evaluate(face(width: 60, height: 240, yaw: 75)).score != nil, "narrow profile box is accepted")
        var profile = face(yaw: 75); profile.roll = 0; profile.excluded = ["rightEye"]
        let profileResult = FaceRatingEngine.evaluate(profile)
        check(profileResult.score != nil && profileResult.metrics.contains { $0.id == "profile" }, "profile uses its own criteria")
        profile.excluded.insert("nose")
        check(FaceRatingEngine.evaluate(profile).score == nil, "covered nose removes profile line score")
        check(FaceRatingEngine.evaluate(face(pitch: 60)).score == nil, "extreme pitch withheld")
        let data = try! JSONEncoder().encode(reference)
        let decoded = try! JSONDecoder().decode(FaceRating.self, from: data)
        check(decoded.score == reference.score && decoded.metrics.count == 4, "report serializes for debugging")
        print("PASS: \(count) face rating checks — quality gates, invariance, weights, bounded results")
    }
}
