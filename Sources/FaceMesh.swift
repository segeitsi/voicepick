import AppKit

struct FaceMesh: Codable {
    let points: [CGPoint]
    let edges: [[Int]]
    var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
}

enum FaceMeshWorker {
    private struct Output: Decodable {
        struct Face: Decodable { let points: [[Double]] }
        let version: Int?
        let width: Int?
        let height: Int?
        let faces: [Face]?
        let edges: [[Int]]?
        let error: String?
    }

    static var bundledExecutable: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("FaceMesh/face-mesh")
    }

    static func decode(_ data: Data, width: Int, height: Int) throws -> [FaceMesh] {
        let output = try JSONDecoder().decode(Output.self, from: data)
        if let error = output.error { throw DesktopError.message("Детектор сетки: \(error)") }
        guard output.version == 1, output.width == width, output.height == height,
              let faces = output.faces, faces.count <= 12, let edges = output.edges,
              !edges.isEmpty, edges.count <= 5000,
              edges.allSatisfy({ $0.count == 2 && $0.allSatisfy { (0..<478).contains($0) } }) else {
            throw DesktopError.message("Детектор вернул несовместимую сетку лица")
        }
        return try faces.map { face in
            guard face.points.count == 478, face.points.allSatisfy({
                $0.count == 2 && $0[0].isFinite && $0[1].isFinite &&
                (-Double(width) * 0.25...Double(width) * 1.25).contains($0[0]) &&
                (-Double(height) * 0.25...Double(height) * 1.25).contains($0[1])
            }) else { throw DesktopError.message("Детектор вернул некорректные точки лица") }
            return FaceMesh(points: face.points.map { CGPoint(x: $0[0], y: $0[1]) }, edges: edges)
        }
    }

    static func detect(_ image: CGImage, executable: URL) throws -> [FaceMesh] {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DesktopError.message("Подробный детектор отсутствует в сборке приложения")
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw DesktopError.message("Не удалось подготовить фото для сетки")
        }
        let input = png.base64EncodedData()
        guard input.count <= 32 * 1024 * 1024 else { throw DesktopError.message("Фото слишком большое для сетки") }
        let process = Process(); process.executableURL = executable
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = ProcessInfo.processInfo.environment["BBDV_MESH_DIAGNOSTICS"] == "1" ? FileHandle.standardError : FileHandle.nullDevice
        // All image bytes stay in local pipes. No screenshot files or network calls.
        var environment = ProcessInfo.processInfo.environment
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("bbdv-mesh-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        environment["MPLCONFIGDIR"] = cache.path
        environment["BBDV_MESH_CACHE"] = cache.path
        environment["PYTHONNOUSERSITE"] = "1"
        process.environment = environment
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        // The first frozen-runtime launch also prepares a local library cache.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
        defer { deadline.cancel(); if process.isRunning { process.terminate() } }
        do { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
        catch { process.terminate(); throw DesktopError.message("Не удалось передать фото локальному детектору") }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard finished.wait(timeout: .now() + 2) == .success, process.terminationStatus == 0 else {
            if let error = try? JSONDecoder().decode(Output.self, from: data).error, !error.isEmpty {
                throw DesktopError.message("Детектор сетки: \(error)")
            }
            throw DesktopError.message("Не удалось построить подробную сетку лица. Повтори разбор фото.")
        }
        return try decode(data, width: image.width, height: image.height)
    }

    static func refine(_ result: FaceAnalysisResult, executable: URL?) -> FaceAnalysisResult {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { return result }
        do {
            let meshes = try detect(result.image, executable: executable)
            var used = Set<Int>()
            var faces = result.faces.map { face -> AnalyzedFace in
                let candidate = meshes.indices.filter { !used.contains($0) }.min {
                    hypot(meshes[$0].bounds.midX - face.box.midX, meshes[$0].bounds.midY - face.box.midY) <
                    hypot(meshes[$1].bounds.midX - face.box.midX, meshes[$1].bounds.midY - face.box.midY)
                }
                guard let candidate else { return face }
                let mesh = meshes[candidate], intersection = mesh.bounds.intersection(face.box)
                guard !intersection.isNull,
                      intersection.width * intersection.height / max(1, min(mesh.bounds.width * mesh.bounds.height, face.box.width * face.box.height)) > 0.25 else { return face }
                used.insert(candidate)
                // Preserve existing reference crops and Vision diagnostics; only the visible mask changes.
                return AnalyzedFace(id: face.id, box: face.box, points: mesh.points, rating: face.rating,
                                    quality: face.quality, geometry: face.geometry, mesh: mesh)
            }
            for index in meshes.indices where !used.contains(index) {
                let mesh = meshes[index], box = mesh.bounds.intersection(CGRect(x: 0, y: 0, width: result.image.width, height: result.image.height))
                let geometry = FaceGeometry(width: box.width, height: box.height, leftEye: [], rightEye: [], nose: [],
                                            lips: [], contour: [], yaw: nil, pitch: nil, quality: nil, confidence: 0)
                faces.append(AnalyzedFace(id: faces.count, box: box, points: mesh.points, rating: FaceRatingEngine.evaluate(geometry),
                                          quality: nil, geometry: geometry, mesh: mesh))
            }
            return FaceAnalysisResult(image: result.image, faces: faces, meshIssue: meshes.isEmpty ? "Подробная сетка не найдена; точки Vision показаны как приблизительные." : nil)
        } catch {
            return FaceAnalysisResult(image: result.image, faces: result.faces, meshIssue: error.localizedDescription)
        }
    }
}
