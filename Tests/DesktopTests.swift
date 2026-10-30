import AppKit

@main
struct DesktopTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1; guard condition() else { fatalError(label) }
        }
        let window = CGRect(x: 100, y: 100, width: 900, height: 700)
        var calibration = Calibration(region: CGRect(x: 120, y: 120, width: 300, height: 350),
                                      input: CGPoint(x: 140, y: 750), window: window, bundle: "com.tdesktop.Telegram")
        check(calibration.isComplete, "valid coordinates")
        check(TargetWindow(pid: 1, bundle: "com.tdesktop.Telegram", frame: window).matches(calibration), "window matches")
        check(!TargetWindow(pid: 1, bundle: "another.app", frame: window).matches(calibration), "wrong app")
        check(!TargetWindow(pid: 1, bundle: "com.tdesktop.Telegram", frame: window.offsetBy(dx: 40, dy: 0)).matches(calibration), "moved window")
        let moved = TargetWindow(pid: 1, bundle: "com.tdesktop.Telegram", frame: window.offsetBy(dx: -450, dy: 65))
        let movedCalibration = moved.resolved(calibration, mode: .voice)!
        check(movedCalibration.input == CGPoint(x: -310, y: 815), "input follows window, including second display")
        check(movedCalibration.region == calibration.region!.offsetBy(dx: -450, dy: 65), "crop follows window")
        check(moved.matches(movedCalibration), "resolved window can start after moving")
        check(moved.resolved(calibration, mode: .random)?.isComplete == true, "random starts after moving")
        check(TargetWindow(pid: 1, bundle: "another.app", frame: window).resolved(calibration, mode: .voice) == nil, "resolution rejects other apps")
        let resizedFrame = CGRect(x: 50, y: 60, width: 1100, height: 800)
        check(TargetWindow(pid: 1, bundle: "com.tdesktop.Telegram", frame: resizedFrame).resolved(calibration, mode: .voice) == nil, "voice requires field reselection after resize")
        check(TargetWindow(pid: 1, bundle: "com.tdesktop.Telegram", frame: resizedFrame).resolved(calibration, mode: .random) == nil, "random requires new crop after resize")
        var knownWindow = calibration
        knownWindow.windowIdentifier = "main"
        check(TargetWindow(pid: 1, bundle: "com.tdesktop.Telegram", frame: window, identifier: "photo-viewer").resolved(knownWindow, mode: .voice) == nil, "reject other Telegram window")
        check(!TargetWindow(pid: 1, bundle: "com.tdesktop.Telegram", frame: window, identifier: "other-window").matches(knownWindow), "window checks preserve known identity before Enter")
        var generic = calibration; generic.bundle = "com.apple.TextEdit"
        check(TargetWindow(pid: 2, bundle: "com.apple.TextEdit", frame: window).resolved(generic, mode: .voice) != nil, "non-Telegram calibrated application is supported")
        check(TargetWindow.permits(bundle: "com.apple.TextEdit", expectedBundle: nil), "calibration can choose a normal application")
        check(TargetWindow.permits(bundle: "com.google.Chrome", expectedBundle: "com.google.Chrome"), "chosen browser is allowed")
        check(!TargetWindow.permits(bundle: "com.apple.TextEdit", expectedBundle: "com.google.Chrome"), "other foreground app cannot receive the answer")
        check(!TargetWindow.permits(bundle: "local.oshi.bbdv", expectedBundle: nil), "application cannot calibrate itself")
        check(!TargetWindow.permits(bundle: "com.apple.loginwindow", expectedBundle: nil), "login window is excluded")
        check(InputFieldPolicy.accepts(role: "AXTextArea", subrole: nil), "normal text areas accepted")
        check(!InputFieldPolicy.accepts(role: "AXTextField", subrole: "AXSecureTextField"), "password fields are excluded")
        check(!InputFieldPolicy.accepts(role: "AXButton", subrole: nil), "buttons cannot be treated as input fields")
        let legacyData = try JSONEncoder().encode(calibration)
        let legacy = try JSONDecoder().decode(Calibration.self, from: legacyData)
        check(legacy.windowIdentifier == nil && moved.resolved(legacy, mode: .voice) != nil, "old calibrations migrate without re-selection")
        calibration.input = CGPoint(x: 0, y: 0)
        check(!calibration.isComplete, "input outside window")
        calibration.input = CGPoint(x: 140, y: 750)
        calibration.region = CGRect(x: 950, y: 120, width: 300, height: 350)
        check(!calibration.isComplete, "region outside window")
        func image(inverted: Bool, blank: Bool = false) -> CGImage {
            let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: blank ? 0.5 : inverted ? 0.9 : 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            if !blank {
                context.setFillColor(CGColor(gray: inverted ? 0.1 : 0.9, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 128))
            }
            return context.makeImage()!
        }
        let a = try ScreenReader.fingerprint(image(inverted: false))
        let b = try ScreenReader.fingerprint(image(inverted: true))
        let blank = try ScreenReader.fingerprint(image(inverted: false, blank: true))
        check(a.samples.count == 3072, "32×32 RGB capture")
        check(a.hasDetail, "image details retained")
        check(!blank.hasDetail, "blank capture rejected")
        check(a.distance(to: b) > 0.7, "different capture detected")
        check(a.distance(to: a) == 0, "same capture unchanged")
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let leftDisplay = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let upperDisplay = CGRect(x: 200, y: -1080, width: 1920, height: 1080)
        let primaryCrop = try ScreenReader.localRegion(CGRect(x: 140, y: 200, width: 300, height: 400), in: primary)
        check(primaryCrop == CGRect(x: 140, y: 200, width: 300, height: 400), "primary display keeps crop coordinates")
        let leftCrop = try ScreenReader.localRegion(CGRect(x: -1800, y: 220, width: 300, height: 400), in: leftDisplay)
        check(leftCrop == CGRect(x: 120, y: 100, width: 300, height: 400), "left display negative coordinates become local")
        let upperCrop = try ScreenReader.localRegion(CGRect(x: 350, y: -900, width: 500, height: 600), in: upperDisplay)
        check(upperCrop == CGRect(x: 150, y: 180, width: 500, height: 600), "upper display top-left origin is preserved")
        for invalid in [CGRect(x: -10, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 79, height: 100),
                        CGRect(x: 1400, y: 900, width: 300, height: 400), CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            do { _ = try ScreenReader.localRegion(invalid, in: primary); fatalError("Invalid screen region was accepted") }
            catch { checks += 1 }
        }
        print("PASS: \(checks) desktop checks — geometry and actual CGImage fingerprints")
    }
}
