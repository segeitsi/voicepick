import AppKit
import Vision
import ImageIO

struct AnalyzedFace: Identifiable {
    let id: Int
    let box: CGRect
    let points: [CGPoint]
    let rating: FaceRating
    let quality: Double?
    let geometry: FaceGeometry
    var mesh: FaceMesh? = nil
}

struct FaceAnalysisResult {
    let image: CGImage
    let faces: [AnalyzedFace]
    var meshIssue: String? = nil
}

enum LocalFaceAnalyzer {
    static func analyze(_ image: CGImage, meshExecutable: URL? = FaceMeshWorker.bundledExecutable) throws -> FaceAnalysisResult {
        var best = try analyzeUpright(image)
        // A detector miss on a tilted/covered face gets a second look at other rolls.
        if best.faces.isEmpty {
            for degrees in [-30.0, 30, -60, 60, -90, 90] {
                let angle = degrees * .pi / 180
                let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                let rotation = CGAffineTransform(rotationAngle: angle)
                let rotatedBounds = bounds.applying(rotation)
                let transform = rotation.concatenating(CGAffineTransform(translationX: -rotatedBounds.minX, y: -rotatedBounds.minY))
                let width = Int(ceil(rotatedBounds.width)), height = Int(ceil(rotatedBounds.height))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.concatenate(transform); context.draw(image, in: bounds)
                guard let rotated = context.makeImage() else { continue }
                let result = try analyzeUpright(rotated)
                if !result.faces.isEmpty {
                    let inverse = transform.inverted()
                    best = FaceAnalysisResult(image: image, faces: result.faces.map {
                        AnalyzedFace(id: $0.id, box: $0.box.applying(inverse).intersection(bounds),
                                     points: $0.points.map { $0.applying(inverse) }, rating: $0.rating,
                                     quality: $0.quality, geometry: $0.geometry)
                    })
                    break
                }
            }
        }
        return FaceMeshWorker.refine(best, executable: meshExecutable)
    }

    private static func analyzeUpright(_ image: CGImage) throws -> FaceAnalysisResult {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        try handler.perform([rectangles])
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        request.constellation = .constellation76Points
        request.inputFaceObservations = rectangles.results ?? []
        try handler.perform([request])
        let observations = (request.results ?? []).sorted {
            $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
        }
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = observations
        try? handler.perform([qualityRequest])
        let size = CGSize(width: image.width, height: image.height)
        let faces = observations.enumerated().map { index, face -> AnalyzedFace in
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                guard let region else { return [] }
                return region.pointsInImage(imageSize: size)
            }
            let box = CGRect(x: face.boundingBox.minX * size.width, y: face.boundingBox.minY * size.height,
                             width: face.boundingBox.width * size.width, height: face.boundingBox.height * size.height)
            let qualityFace = qualityRequest.results?.min {
                hypot($0.boundingBox.midX - face.boundingBox.midX, $0.boundingBox.midY - face.boundingBox.midY) <
                hypot($1.boundingBox.midX - face.boundingBox.midX, $1.boundingBox.midY - face.boundingBox.midY)
            }
            let quality = qualityFace?.faceCaptureQuality.map(Double.init)
            let landmarks = face.landmarks
            let geometry = FaceGeometry(width: box.width, height: box.height,
                                        leftEye: points(landmarks?.leftEye), rightEye: points(landmarks?.rightEye),
                                        nose: points(landmarks?.nose), lips: points(landmarks?.outerLips),
                                        contour: points(landmarks?.faceContour),
                                        yaw: face.yaw.map { $0.doubleValue * 180 / .pi },
                                        pitch: face.pitch.map { $0.doubleValue * 180 / .pi },
                                        quality: quality, confidence: Double(landmarks?.confidence ?? 0),
                                        roll: face.roll.map { $0.doubleValue * 180 / .pi },
                                        reliability: reliability(landmarks))
            return AnalyzedFace(id: index, box: box, points: points(landmarks?.allPoints),
                                rating: FaceRatingEngine.evaluate(geometry), quality: quality, geometry: geometry)
        }
        return FaceAnalysisResult(image: image, faces: faces)
    }

    private static func reliability(_ landmarks: VNFaceLandmarks2D?) -> [String: Double] {
        let regions: [(String, VNFaceLandmarkRegion2D?)] = [
            ("leftEye", landmarks?.leftEye), ("rightEye", landmarks?.rightEye),
            ("nose", landmarks?.nose), ("lips", landmarks?.outerLips), ("contour", landmarks?.faceContour)
        ]
        var result: [String: Double] = [:]
        for (name, region) in regions {
            guard let values = region?.precisionEstimatesPerPoint, !values.isEmpty else { continue }
            result[name] = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        }
        return result
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else { throw DesktopError.message("Не удалось открыть изображение.") }
        return image
    }
}
