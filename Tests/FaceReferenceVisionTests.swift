import AppKit

@main
struct FaceReferenceVisionTests {
    static func main() throws {
        let bankURL = URL(fileURLWithPath: "assets/drawing-references.json")
        guard FileManager.default.fileExists(atPath: bankURL.path) else {
            print("SKIP: optional local drawing bank is absent; user examples are not part of the repository")
            return
        }
        let bank = try FaceReferenceBank.read(bankURL)
        guard bank.references.count == 7, Set(bank.references.map(\.tier)).count == 7,
              bank.references.allSatisfy({ $0.kind == .drawing }) else { fatalError("Drawing bank must cover all categories") }
        for reference in bank.references {
            let print = try FaceReferenceVision.decode(reference.feature)
            guard try FaceReferenceVision.distance(print, print) < 0.0001,
                  let thumbnail = NSImage(data: reference.thumbnail), thumbnail.size.width == 144 else {
                fatalError("Archive or thumbnail corrupted")
            }
        }
        print("PASS: all seven feature archives and thumbnails are readable")
        guard CommandLine.arguments.count > 1 else { return }
        let image = try LocalFaceAnalyzer.load(URL(fileURLWithPath: CommandLine.arguments[1]))
        let result = try LocalFaceAnalyzer.analyze(image)
        guard result.faces.count == 7 else { fatalError("Expected seven chart faces") }
        let rows = result.faces.sorted { $0.box.midY > $1.box.midY }
        let ordered = Array(rows.prefix(3)).sorted { $0.box.midX < $1.box.midX } +
            Array(rows.dropFirst(3).prefix(3)).sorted { $0.box.midX < $1.box.midX } + Array(rows.suffix(1))
        for (face,tier) in zip(ordered,FaceTier.allCases) {
            let match = try FaceReferenceVision.match(image, box: face.box, references: bank.references)
            guard match.category == tier, let first = match.nearest.first, first.distance < 0.0001 else {
                fatalError("Source sample must match its annotated category \(tier.rawValue), got \(String(describing: match))")
            }
            print("PASS: source sample \(tier.rawValue) matches its stored label (pipeline check only)")
        }
        // Photo and drawing banks remain separate, even with identical features.
        let photos = bank.references.filter { $0.kind == .photo }
        let photoMatch = try FaceReferenceVision.match(image, box: ordered[0].box, references: photos)
        guard photoMatch.category == nil, photoMatch.nearest.isEmpty else { fatalError("Drawing data must not rate a photo") }
        print("PASS: empty photo bank never falls back to drawing labels")
        // Verify crop origin with a synthetic two-colour image, independent of face detection.
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x:0,y:100,width:200,height:100))
        ctx.setFillColor(NSColor.blue.cgColor); ctx.fill(CGRect(x:0,y:0,width:200,height:100))
        let crop = try FaceReferenceVision.crop(ctx.makeImage()!, box: CGRect(x:60,y:130,width:60,height:50))
        let pixels = NSBitmapImageRep(cgImage: crop)
        let color = pixels.colorAt(x: crop.width / 2, y: crop.height / 2)!.usingColorSpace(.deviceRGB)!
        guard color.redComponent > 0.9 && color.blueComponent < 0.1 else { fatalError("Crop must respect Vision bottom-left coordinates") }
        print("PASS: face crop uses the correct vertical image coordinates")
    }
}
