import AppKit

@main
struct ScreenWatchTests {
    @MainActor
    static func main() async throws {
        func image(_ inverted: Bool) -> CGImage {
            let context = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 480,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: inverted ? 1 : 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            context.setFillColor(CGColor(gray: inverted ? 0 : 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 60, height: 120))
            return context.makeImage()!
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("Screen observation did not reach expected state")
        }
        let first = image(false), second = image(true)
        let region = CGRect(x: -600, y: 200, width: 120, height: 120)
        var analyses = 0, captures = 0, changed = false
        let model = FaceDebugModel(capture: { requested in
            guard requested == region else { fatalError("Capture escaped the selected region") }
            captures += 1
            return changed ? second : first
        }, analyze: { image in
            analyses += 1
            return FaceAnalysisResult(image: image, faces: [])
        }, canCapture: { true }, pollInterval: .milliseconds(10))
        model.region = region; model.watch()
        try await waitUntil { model.result != nil }
        guard captures >= 2, analyses == 1, model.watching else { fatalError("Need two stable frames before analysis") }
        try await Task.sleep(for: .milliseconds(50))
        guard analyses == 1 else { fatalError("Unchanged frame must not be re-analyzed") }
        changed = true
        try await waitUntil { analyses == 2 && model.result != nil }
        guard model.result?.image === second else { fatalError("Changed desktop must replace old result") }
        model.stop()
        let stoppedCaptures = captures
        try await Task.sleep(for: .milliseconds(50))
        guard !model.watching, captures == stoppedCaptures else { fatalError("Stop must end desktop reads") }

        var unauthorizedReads = 0
        let denied = FaceDebugModel(capture: { _ in unauthorizedReads += 1; return first }, canCapture: { false })
        denied.region = region; denied.watch()
        guard !denied.watching, unauthorizedReads == 0 else { fatalError("Denied screen access must never capture") }

        let failed = FaceDebugModel(capture: { _ in throw DesktopError.message("Test capture failure") }, canCapture: { true })
        failed.region = region; failed.watch()
        try await waitUntil { !failed.watching }
        guard failed.status == "Test capture failure" else { fatalError("Capture errors must stop observation with a reason") }

        var pending: CheckedContinuation<CGImage, Error>?
        let delayed = FaceDebugModel(capture: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }, canCapture: { true }, pollInterval: .milliseconds(10))
        delayed.region = region; delayed.watch()
        try await waitUntil { pending != nil }
        delayed.stop(); pending?.resume(returning: first)
        try await Task.sleep(for: .milliseconds(50))
        guard delayed.result == nil, !delayed.watching else { fatalError("A late capture must not revive stopped observation") }
        print("PASS: desktop observation — selected crop, stable frames, changed image, stop, permission denial, capture failure and cancellation")
    }
}
