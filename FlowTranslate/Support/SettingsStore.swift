import Foundation
import FlowTranslateCore

/// Persists `CaptionSettings` to UserDefaults as JSON so user preferences
/// (languages, font size, click-through, ASR tier) survive relaunches.
enum SettingsStore {
    private static let key = "FlowTranslate.CaptionSettings"

    static func load() -> CaptionSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(CaptionSettings.self, from: data)
        else { return .default }
        return settings
    }

    static func save(_ settings: CaptionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
