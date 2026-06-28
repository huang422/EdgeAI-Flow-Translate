import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct CaptionSettingsTests {
    @Test func defaultsAreEnglishToTraditionalChinese() {
        let s = CaptionSettings.default
        #expect(s.firstLanguage == "en-US")
        #expect(s.secondCaptionEnabled == true)
        #expect(s.secondLanguage == .traditionalChinese)
        #expect(s.needsTranslation == true)
    }

    @Test func secondCaptionCanBeDisabled() {
        var s = CaptionSettings.default
        s.secondCaptionEnabled = false
        #expect(s.needsTranslation == false)
    }

    @Test func englishToEnglishNeedsNoTranslation() {
        let s = CaptionSettings(firstLanguage: "en-US", secondLanguage: .english)
        #expect(s.needsTranslation == false)
    }

    @Test func supportedLanguagesCoverExpectedCount() {
        // 19 transcription-ready + 13 broad-coverage = 32
        #expect(SupportedASRLanguages.all.count == 32)
        #expect(SupportedASRLanguages.locale(for: "en-US") != nil)
    }

    @Test func autoCloseOverlayDefaultsOff() {
        // Stopping a meeting must NOT hide the overlay unless the user opts in.
        #expect(CaptionSettings.default.autoCloseOverlayOnStop == false)
    }

    @Test func tolerantDecodeMissingAutoCloseDefaultsOff() throws {
        // Older persisted JSON (no overlay auto-close key) upgrades cleanly to off.
        let json = Data(#"{"firstLanguage":"en-US"}"#.utf8)
        let s = try JSONDecoder().decode(CaptionSettings.self, from: json)
        #expect(s.autoCloseOverlayOnStop == false)
        #expect(s.firstLanguage == "en-US")
    }

    @Test func roundTripPreservesAutoClose() throws {
        var s = CaptionSettings.default
        s.autoCloseOverlayOnStop = true
        let back = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.autoCloseOverlayOnStop == true)
    }
}
