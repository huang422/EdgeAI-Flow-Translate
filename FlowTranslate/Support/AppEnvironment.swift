import Foundation

/// Temporary UI-fixture bundles never use production preferences/transcripts,
/// register hotkeys, request permissions, or download models.
enum AppEnvironment {
    static let fixtureNotification = Notification.Name("FlowTranslate.UIFixtureScenario")
    static let isUIFixture = Bundle.main.object(forInfoDictionaryKey: "FlowTranslateUIFixture") as? Bool == true
    static let fixtureScenario = Bundle.main.object(forInfoDictionaryKey: "FlowTranslateFixtureScenario") as? String ?? "first-launch"
    static var preferences: UserDefaults {
        isUIFixture ? UserDefaults(suiteName: "\(Bundle.main.bundleIdentifier!).fixture")! : .standard
    }
    static var dataDirectory: URL {
        if isUIFixture {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "flowtranslate-ui-fixture")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowTranslate", isDirectory: true)
    }
    static func fixtureDimension(_ name: String, fallback: Double) -> Double {
        Bundle.main.object(forInfoDictionaryKey: "FlowTranslateFixture\(name)") as? Double ?? fallback
    }
}
