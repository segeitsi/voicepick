import Foundation

@main
struct SettingsTests {
    static func main() throws {
        let old = Data(#"{"service":"davinchik","mode":"voice","minimum":3,"maximum":8,"likePercent":65,"likeEmoji":"yes","dislikeEmoji":"no","sensitivity":0.12,"calibrations":{"davinchik":{"bundle":"com.tdesktop.Telegram"}}}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: old)
        guard settings.inputKind == .reaction, settings.sendReturn,
              settings.minimum == 3, settings.maximum == 8, settings.likePercent == 65,
              settings.likeEmoji == "yes", settings.dislikeEmoji == "no",
              settings.calibrations[InputKind.reaction.rawValue]?.bundle == "com.tdesktop.Telegram" else {
            fatalError("Existing settings and automatic Enter must survive the new name")
        }
        guard InputKind(rawValue: "bibinta") == .rating, !Settings().sendReturn else {
            fatalError("Legacy numeric key survives; fresh settings default to input without Enter")
        }
        var updated = settings; updated.sendReturn = false
        let data = try JSONEncoder().encode(updated)
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        guard !restored.sendReturn, restored.inputKind == .reaction, restored.likeEmoji == "yes",
              restored.calibrations.count == settings.calibrations.count else { fatalError("Settings roundtrip") }
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard object["service"] as? String == "davinchik" else { fatalError("Stored selector key must remain compatible") }
        print("PASS: VoicePick settings — legacy keys, calibration, custom responses, Enter migration and new defaults")
    }
}
