import AppKit

@main
struct FaceMeshTests {
    static func main() throws {
        let points = (0..<478).map { [Double($0 % 30 + 20), Double($0 % 40 + 10)] }
        let valid: [String: Any] = ["version": 1, "width": 100, "height": 80,
                                  "faces": [["points": points]], "edges": [[0, 1], [1, 2]]]
        func decode(_ object: [String: Any]) throws -> [FaceMesh] {
            try FaceMeshWorker.decode(JSONSerialization.data(withJSONObject: object), width: 100, height: 80)
        }
        func rejects(_ key: String, _ value: Any) {
            var bad = valid; bad[key] = value
            do { _ = try decode(bad); fatalError("Accepted malformed \(key)") } catch { }
        }
        let meshes = try decode(valid)
        guard meshes.count == 1, meshes[0].points.count == 478, meshes[0].bounds.minY == 10 else {
            fatalError("Mesh coordinates must retain bottom-left pixel units")
        }
        let roundtrip = try JSONDecoder().decode(FaceMesh.self, from: JSONEncoder().encode(meshes[0]))
        guard roundtrip.points == meshes[0].points, roundtrip.edges == meshes[0].edges else { fatalError("Mesh report roundtrip") }
        rejects("version", 2); rejects("width", 101); rejects("height", 79)
        rejects("edges", [[0, 478]]); rejects("edges", [[-1, 2]]); rejects("edges", [[1]])
        rejects("edges", []); rejects("faces", [["points": Array(points.dropLast())]])
        rejects("faces", [["points": [[1000.0, 20.0]] + Array(points.dropFirst())]])
        var empty = valid; empty["faces"] = []
        guard try decode(empty).isEmpty else { fatalError("Empty output must stay empty") }
        print("PASS: face mesh protocol rejects malformed coordinates, dimensions and edges; report retains all points")
        guard CommandLine.arguments.contains("--native") else { return }
        let worker = URL(fileURLWithPath: "build/mesh-dist/face-mesh/face-mesh")
        guard FileManager.default.isExecutableFile(atPath: worker.path) else { fatalError("Build the packaged mesh worker first") }
        let blank = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        blank.setFillColor(CGColor(gray: 0.5, alpha: 1)); blank.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        guard try FaceMeshWorker.detect(blank.makeImage()!, executable: worker).isEmpty else { fatalError("Blank mesh false positive") }
        do { _ = try FaceMeshWorker.detect(blank.makeImage()!, executable: URL(fileURLWithPath: "/usr/bin/false")); fatalError("Helper failure was accepted") }
        catch { }
        let portrait = URL(fileURLWithPath: "build/fixtures/portrait.jpg")
        if FileManager.default.fileExists(atPath: portrait.path) {
            let image = try LocalFaceAnalyzer.load(portrait)
            let baseline = try LocalFaceAnalyzer.analyze(image, meshExecutable: nil)
            let enhanced = try LocalFaceAnalyzer.analyze(image, meshExecutable: worker)
            guard enhanced.meshIssue == nil, enhanced.faces.count == 1, let face = enhanced.faces.first,
                  face.mesh != nil, face.points.count == 478, face.box == baseline.faces[0].box,
                  face.points.allSatisfy({ (0...Double(image.width)).contains($0.x) && (0...Double(image.height)).contains($0.y) }) else {
                fatalError("Packaged mesh must refine one portrait, preserving reference crop and source coordinates")
            }
            let tiltedContext = CGContext(data: nil, width: 900, height: 900, bitsPerComponent: 8,
                                          bytesPerRow: 900 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            tiltedContext.translateBy(x: 450, y: 450); tiltedContext.rotate(by: .pi / 3)
            tiltedContext.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
            let tilted = try FaceMeshWorker.detect(tiltedContext.makeImage()!, executable: worker)
            func center(_ points: [CGPoint]) -> CGPoint {
                CGPoint(x: points.map(\.x).reduce(0,+) / Double(points.count), y: points.map(\.y).reduce(0,+) / Double(points.count))
            }
            let originalCenter = center(face.mesh!.points)
            let expected = CGPoint(x: originalCenter.x - Double(image.width) / 2, y: originalCenter.y - Double(image.height) / 2)
                .applying(CGAffineTransform(rotationAngle: .pi / 3)).applying(CGAffineTransform(translationX: 450, y: 450))
            guard tilted.count == 1 else { fatalError("Tilted portrait must have a detailed mesh") }
            let actual = center(tilted[0].points)
            guard hypot(actual.x - expected.x, actual.y - expected.y) < 30 else { fatalError("Mesh must follow rotation in original image coordinates") }
            let pair = CGContext(data: nil, width: image.width * 2, height: image.height, bitsPerComponent: 8,
                                 bytesPerRow: image.width * 2 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            pair.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            pair.draw(image, in: CGRect(x: image.width, y: 0, width: image.width, height: image.height))
            let group = try LocalFaceAnalyzer.analyze(pair.makeImage()!, meshExecutable: worker)
            guard group.meshIssue == nil, group.faces.count == 2, group.faces.allSatisfy({ $0.mesh != nil }),
                  abs(group.faces[0].mesh!.bounds.midX - group.faces[1].mesh!.bounds.midX) > Double(image.width) * 0.8 else {
                fatalError("Two faces must have independent mesh associations")
            }
        }
        for path in CommandLine.arguments.dropFirst().filter({ $0 != "--native" }) {
            let result = try LocalFaceAnalyzer.analyze(LocalFaceAnalyzer.load(URL(fileURLWithPath: path)), meshExecutable: worker)
            guard result.meshIssue == nil, result.faces.count == 1, result.faces[0].mesh?.points.count == 478 else {
                fatalError("Expected detailed mesh on supplied regression image")
            }
            print("PASS: supplied image \(result.image.width)×\(result.image.height), one 478-point mesh")
        }
        print("PASS: self-contained worker, blank image, helper failure, portrait, rotation and two-face matching")
    }
}
