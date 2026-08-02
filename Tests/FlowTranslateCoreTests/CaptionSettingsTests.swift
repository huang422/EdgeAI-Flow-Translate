import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct CaptionSettingsTests {
    @Test func defaultsAreEnglishToTraditionalChinese() {
        // The shipped configuration: English in, Traditional Chinese out, the
        // lowest-latency tier, with speakers labelled.
        let s = CaptionSettings.default
        #expect(s.firstLanguage == "en-US")
        #expect(s.asrTier == "560ms")
        #expect(s.secondCaptionEnabled == true)
        #expect(s.secondLanguage == .traditionalChinese)
        #expect(s.needsTranslation == true)
        #expect(s.diarizationEnabled == true)
    }

    @Test func roundTripPreservesDiarizationSetting() throws {
        var s = CaptionSettings.default
        s.diarizationEnabled = false
        let back = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.diarizationEnabled == false)
    }

    @Test func acousticContextExperimentDefaultsOff() {
        #expect(CaptionSettings.default.keepAcousticContext == false)
    }

    @Test func roundTripPreservesAcousticContextSetting() throws {
        var s = CaptionSettings.default
        s.keepAcousticContext = true
        let back = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.keepAcousticContext == true)
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
        // 19 transcription-ready + 14 broad-coverage = 33
        #expect(SupportedASRLanguages.all.count == 33)
        #expect(SupportedASRLanguages.locale(for: "en-US") != nil)
    }

    @Test func bothMandarinLocalesAreOffered() {
        // The model ships separate prompts for them (zh-CN → 4, zh-TW → 5), so
        // offering only one meant Taiwanese Mandarin ran under the Mainland prompt.
        #expect(SupportedASRLanguages.locale(for: "zh-CN") != nil)
        #expect(SupportedASRLanguages.locale(for: "zh-TW") != nil)
    }

    @Test func traditionalSourceNeedsNoTranslationToTraditional() {
        // zh-TW already recognizes into Traditional characters — translating it
        // to Traditional Chinese would burn a generation to reproduce the input.
        let s = CaptionSettings(firstLanguage: "zh-TW", secondLanguage: .traditionalChinese)
        #expect(s.needsTranslation == false)
    }

    @Test func simplifiedSourceStillConvertsToTraditional() {
        let s = CaptionSettings(firstLanguage: "zh-CN", secondLanguage: .traditionalChinese)
        #expect(s.needsTranslation == true)
    }

    @Test func mandarinToEnglishAlwaysTranslates() {
        #expect(CaptionSettings(firstLanguage: "zh-TW", secondLanguage: .english).needsTranslation)
        #expect(CaptionSettings(firstLanguage: "zh-CN", secondLanguage: .english).needsTranslation)
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

    @Test func transcriptCorrectionDefaultsOff() {
        // It keeps the ~2.5 GB model resident for the whole meeting, so it has to
        // be something the user opts into knowingly.
        #expect(CaptionSettings.default.transcriptCorrectionEnabled == false)
    }

    @Test func tolerantDecodeMissingCorrectionKeyDefaultsOff() throws {
        let json = Data(#"{"firstLanguage":"en-US"}"#.utf8)
        let s = try JSONDecoder().decode(CaptionSettings.self, from: json)
        #expect(s.transcriptCorrectionEnabled == false)
    }

    @Test func roundTripPreservesCorrectionSetting() throws {
        var s = CaptionSettings.default
        s.transcriptCorrectionEnabled = true
        let back = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.transcriptCorrectionEnabled == true)
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
