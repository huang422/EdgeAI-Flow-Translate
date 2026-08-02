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
        #expect(s.diarizationEnabled == false)
    }

    @Test func roundTripPreservesDiarizationSetting() throws {
        var s = CaptionSettings.default
        s.diarizationEnabled = true
        let back = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.diarizationEnabled == true)
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

    @Test func translationEngineDefaultsToSystem() {
        #expect(CaptionSettings.default.translationEngine == .system)
    }

    @Test func tolerantDecodeMissingEngineDefaultsToSystem() throws {
        // Older persisted JSON (no engine key) upgrades cleanly to the system engine.
        let json = Data(#"{"firstLanguage":"en-US"}"#.utf8)
        let s = try JSONDecoder().decode(CaptionSettings.self, from: json)
        #expect(s.translationEngine == .system)
    }

    @Test func roundTripPreservesQwenEngine() throws {
        var s = CaptionSettings.default
        s.translationEngine = .qwen
        let back = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.translationEngine == .qwen)
    }

    @Test func inputGainDefaultsAreOff() {
        let s = CaptionSettings.default
        #expect(s.systemInputGainDb == 0)
        #expect(s.micInputGainDb == 0)
        #expect(s.autoGainEnabled == false)
    }

    @Test func inputGainIsClampedToRange() {
        let hi = CaptionSettings(systemInputGainDb: 999, micInputGainDb: -5)
        #expect(hi.systemInputGainDb == CaptionSettings.maxInputGainDb)
        #expect(hi.micInputGainDb == 0)
    }

    @Test func tolerantDecodeMissingGainDefaultsOff() throws {
        // Older persisted JSON (no gain keys) upgrades cleanly to off/unity.
        let json = Data(#"{"firstLanguage":"en-US"}"#.utf8)
        let s = try JSONDecoder().decode(CaptionSettings.self, from: json)
        #expect(s.systemInputGainDb == 0)
        #expect(s.micInputGainDb == 0)
        #expect(s.autoGainEnabled == false)
    }

    @Test func roundTripPreservesGainSettings() throws {
        var s = CaptionSettings.default
        s.systemInputGainDb = 12
        s.micInputGainDb = 6
        s.autoGainEnabled = true
        let back = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.systemInputGainDb == 12)
        #expect(back.micInputGainDb == 6)
        #expect(back.autoGainEnabled == true)
    }
}
