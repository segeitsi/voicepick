import AppKit

@main
struct FaceVisionTests {
    static func main() throws {
        let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
                                bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let empty = try LocalFaceAnalyzer.analyze(context.makeImage()!)
        guard empty.faces.isEmpty else { fatalError("Blank photo must have no face or rating") }
        print("PASS: native Vision does not rate a blank image")
        let portrait = URL(fileURLWithPath: "build/fixtures/portrait.jpg")
        if FileManager.default.fileExists(atPath: portrait.path) {
            let image = try LocalFaceAnalyzer.load(portrait)
            let result = try LocalFaceAnalyzer.analyze(image)
            guard result.faces.count == 1, let face = result.faces.first,
                  face.points.count == 76, let score = face.rating.score, (1...10).contains(score) else {
                fatalError("Known frontal test portrait must produce landmarks and a finite rating")
            }
            let tiltedContext = CGContext(data: nil, width: 900, height: 900, bitsPerComponent: 8,
                                          bytesPerRow: 900 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            tiltedContext.translateBy(x: 450, y: 450); tiltedContext.rotate(by: .pi / 3)
            tiltedContext.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
            let tilted = try LocalFaceAnalyzer.analyze(tiltedContext.makeImage()!)
            func center(_ points: [CGPoint]) -> CGPoint {
                CGPoint(x: points.map(\.x).reduce(0,+) / Double(points.count), y: points.map(\.y).reduce(0,+) / Double(points.count))
            }
            let originalCenter = center(face.points)
            let expected = CGPoint(x: originalCenter.x - Double(image.width) / 2, y: originalCenter.y - Double(image.height) / 2)
                .applying(CGAffineTransform(rotationAngle: .pi / 3)).applying(CGAffineTransform(translationX: 450, y: 450))
            guard tilted.faces.count == 1, tilted.faces[0].points.allSatisfy({ (0...900).contains($0.x) && (0...900).contains($0.y) }),
                  tilted.image.width == 900 else { fatalError("Tilted portrait must have landmarks in the original image coordinates") }
            let actual = center(tilted.faces[0].points)
            guard hypot(actual.x - expected.x, actual.y - expected.y) < 30 else { fatalError("Landmarks must follow the source image transform") }
            // Two independently placed copies must remain two selectable faces.
            let pair = CGContext(data: nil, width: image.width * 2, height: image.height, bitsPerComponent: 8,
                                 bytesPerRow: image.width * 2 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            pair.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            pair.draw(image, in: CGRect(x: image.width, y: 0, width: image.width, height: image.height))
            let group = try LocalFaceAnalyzer.analyze(pair.makeImage()!)
            guard group.faces.count == 2, group.faces[0].id != group.faces[1].id else {
                fatalError("Two faces must remain distinct selections")
            }
            print("PASS: native Vision finds 76 landmarks on a real portrait on a tilted image and separates two faces")
        }
        for path in CommandLine.arguments.dropFirst() {
            let result = try LocalFaceAnalyzer.analyze(LocalFaceAnalyzer.load(URL(fileURLWithPath: path)))
            print("Image: \(result.image.width)×\(result.image.height), faces: \(result.faces.count)")
            for face in result.faces {
                print("Pose: \(face.geometry.yaw ?? -999), roll: \(face.geometry.roll ?? -999), precision: \(face.geometry.reliability)")
                print("Face \(face.id + 1): \(face.points.count) landmarks, rating: \(face.rating.score.map(String.init(describing:)) ?? "withheld"), \(face.rating.reason ?? "geometry ready")")
            }
        }
    }
}
