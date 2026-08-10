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
        // 19 transcription-ready + 13 broad-coverage = 32. It was 33 until
        // `zh-TW` was removed: no shipped model variant has a `<zh-TW>` tag.
        #expect(SupportedASRLanguages.all.count == 32)
        #expect(SupportedASRLanguages.locale(for: "en-US") != nil)
    }

    /// One Mandarin locale, because the model has one tag.
    ///
    /// This test used to assert the opposite, on the belief that Nemotron prompts
    /// the two separately. Every shipped variant's `tokenizer.json` says
    /// otherwise — `<zh-CN>` exists, `<zh-TW>` does not — and offering the second
    /// left the language lock hunting for a missing tag, which is what produced
    /// garbled captions.
    @Test func onlyTheMandarinLocaleTheModelHasIsOffered() {
        #expect(SupportedASRLanguages.locale(for: "zh-CN") != nil)
        #expect(SupportedASRLanguages.locale(for: "zh-TW") == nil)
    }

    @Test func traditionalSourceNeedsNoTranslationToTraditional() {
        // Mandarin recognition into a Traditional second caption needs no
        // translation — the script guard converts it, and a generation spent
        // reproducing the input would be pure cost.
        let s = CaptionSettings(firstLanguage: "zh-CN", secondLanguage: .traditionalChinese)
        #expect(s.needsTranslation == false)
    }

    @Test func mandarinToEnglishAlwaysTranslates() {
        #expect(CaptionSettings(firstLanguage: "zh-CN", secondLanguage: .english).needsTranslation)
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

/// Settings written by an earlier build must keep working. Every prompt field
/// was added after the first release, so an existing user's stored JSON has none
/// of them — decoding has to fall back to the defaults rather than failing and
/// resetting everything the user configured.
@Suite("Prompt settings migration")
struct PromptSettingsMigrationTests {

    @Test("settings saved before the Prompt tab existed still decode")
    func legacySettingsDecode() throws {
        let legacy = #"""
        {"firstLanguage":"en-US","secondCaptionEnabled":true,"secondLanguage":"zh-Hant",
         "translationEngine":"system","clickThrough":false,"asrTier":"1120ms",
         "diarizationEnabled":false,"keepAcousticContext":false,
         "transcriptCorrectionEnabled":false,"systemInputGainDb":0,"micInputGainDb":0,
         "autoGainEnabled":false,"scenario":"video","primaryLineOnTop":"original",
         "historyLineCount":1,"interimStyle":"dimmedWithCaret","overlayOpacity":0.7,
         "overlayFontSize":16}
        """#
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: Data(legacy.utf8))
        let defaults = CaptionSettings()

        // The user's own choices survive.
        #expect(decoded.firstLanguage == "en-US")
        #expect(decoded.asrTier == "1120ms")
        // The new fields take their defaults instead of failing the whole decode.
        #expect(decoded.promptOutputLanguage == defaults.promptOutputLanguage)
        #expect(decoded.promptLayout == defaults.promptLayout)
        #expect(decoded.promptRuleCategories == Set(RuleCategory.allCases))
    }

    @Test("prompt settings round-trip")
    func promptSettingsRoundTrip() throws {
        var settings = CaptionSettings()
        settings.promptLayout = .codexMarkdown
        settings.promptRuleCategories = [.coding, .workflow]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: data)

        #expect(decoded.promptLayout == .codexMarkdown)
        #expect(decoded.promptRuleCategories == [.coding, .workflow])
    }
}

/// The defaults are the whole product for anyone who never opens Settings, so
/// they are pinned rather than left to drift.
@Suite("Prompt defaults")
struct PromptDefaultsTests {

    @Test("bare symbols by default, because the fallback is now cheap")
    func symbolModeDefault() {
        #expect(CaptionSettings().promptSymbolMode == .symbolsAssumeRulebook)
    }

    /// The reason that default is safe: an unsynced project writes the
    /// constraint out instead of emitting a symbol nothing defines, and that
    /// costs less than the legend it used to fall back to.
    @Test("an unsynced project degrades to full sentences, not to a legend")
    func unsyncedFallbackIsCheap() {
        #expect(SymbolCompressor.effectiveMode(
            requested: .symbolsAssumeRulebook, usedSymbols: ["NO_DEPS"], syncedSymbols: []
        ) == .off)
    }

    /// The sync destination follows the target agent instead of a switch of its
    /// own: Claude Code reads `.claude/rules/`, Codex reads AGENTS.md, and
    /// neither reads the other's — so "which agent" already answers "which file".
    @Test("the target agent decides the sync destination")
    func syncTargetFollowsTheAgent() {
        #expect(PromptLayout.claudeXML.backend == .claude)
        #expect(PromptLayout.codexMarkdown.backend == .codex)
    }

    @Test("every rule category is installed unless narrowed")
    func categoryDefault() {
        #expect(CaptionSettings().promptRuleCategories == Set(RuleCategory.allCases))
    }
}

/// The master switch and the hotkey are separate decisions.
///
/// They were one field, and the on-page checkbox labelled "⌃⌥Space hotkey" was
/// bound to it — so unticking the hotkey hid the tab the checkbox was drawn on,
/// switched the window back to captions, and took the tab picker with it. There
/// was no way back except Settings.
@Suite("Prompt enable vs hotkey")
struct PromptEnableAndHotkeyTests {

    @Test("the hotkey is the only switch, and it defaults on")
    func hotkeyIsTheOnlySwitch() {
        var settings = CaptionSettings()
        #expect(settings.promptHotkeyEnabled)
        settings.promptHotkeyEnabled = false
        #expect(!settings.promptHotkeyEnabled)
    }

    /// Settings written before the split must not silently turn the hotkey off.
    @Test("settings without the new field keep the hotkey")
    func legacySettingsKeepTheHotkey() throws {
        // Includes the removed master switch: a settings file written before
        // the field was dropped must still decode, ignoring what no longer
        // exists rather than failing and resetting everything else.
        let legacy = #"{"firstLanguage":"en-US","promptComposerEnabled":false}"#
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: Data(legacy.utf8))
        #expect(decoded.promptHotkeyEnabled)
        #expect(decoded.firstLanguage == "en-US")
    }

    @Test("enable and hotkey round-trip independently")
    func roundTrip() throws {
        var settings = CaptionSettings()
        settings.promptHotkeyEnabled = false
        let decoded = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(settings)
        )
        #expect(!decoded.promptHotkeyEnabled)
    }
}

/// Dictation language is independent of the captions language: they are
/// different activities, and tying them together bought only a download saving
/// the UI already discloses.
@Suite("Dictation language")
struct DictationLanguageTests {

    @Test("three options, and mixed is the default")
    func defaultIsMixed() {
        #expect(CaptionSettings().promptDictationLanguage == "auto")
    }

    /// A settings file saved when "follow the captions language" existed must
    /// not silently keep following something the UI no longer offers.
    @Test("an empty stored value migrates to mixed")
    func emptyMigratesToMixed() throws {
        let legacy = #"{"firstLanguage":"en-US","promptDictationLanguage":""}"#
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: Data(legacy.utf8))
        #expect(decoded.promptDictationLanguage.isEmpty)
        // The stored value is preserved, but resolution no longer follows captions.
        #expect(PromptDictationResolution.language(for: decoded) == "auto")
    }

    @Test("an explicit choice is used as given")
    func explicitChoiceIsUsed() {
        var settings = CaptionSettings()
        settings.firstLanguage = "en-US"
        settings.promptDictationLanguage = "zh-TW"
        #expect(PromptDictationResolution.language(for: settings) == "zh-TW")
    }

    /// Both engines now store the language the user picked, and the Nemotron
    /// model tag is derived at the point of use. A file written while the picker
    /// stored `zh-CN` has to land on the row that is actually offered, or the
    /// Picker renders blank and the choice cannot be changed back.
    @Test("a stored Nemotron model tag migrates to the language it meant")
    func legacyModelTagMigrates() throws {
        let legacy = #"{"firstLanguage":"en-US","promptDictationLanguage":"zh-CN"}"#
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: Data(legacy.utf8))
        #expect(decoded.promptDictationLanguage == "zh-TW")
    }

    @Test("the other two codes are untouched")
    func otherCodesSurviveTheMigration() throws {
        for code in ["en-US", "auto"] {
            let json = #"{"promptDictationLanguage":"\#(code)"}"#
            let decoded = try JSONDecoder().decode(CaptionSettings.self, from: Data(json.utf8))
            #expect(decoded.promptDictationLanguage == code)
        }
    }
}

/// Mirror of the app-target `PromptDictation` resolution, so the rule can be
/// tested without the app target.
enum PromptDictationResolution {
    static func language(for settings: CaptionSettings) -> String {
        let configured = settings.promptDictationLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "auto" : configured
    }
}

/// Rule categories are stored as the set that is switched **off**, so a
/// category added in a later version arrives switched on.
@Suite("Rule category defaults")
struct RuleCategoryDefaultTests {

    @Test("every category is on by default")
    func allOnByDefault() {
        #expect(CaptionSettings().promptRuleCategoriesOff.isEmpty)
        #expect(CaptionSettings().promptRuleCategories == Set(RuleCategory.allCases))
    }

    /// The reason for storing the complement: a settings file written before a
    /// category existed cannot have deselected it, so it must not arrive off.
    @Test("a category added later arrives switched on")
    func newCategoriesArriveOn() throws {
        // A file that switched off one category the user actually saw.
        let stored = #"{"firstLanguage":"en-US","promptRuleCategoriesOff":["git"]}"#
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: Data(stored.utf8))
        #expect(!decoded.promptRuleCategories.contains(.git))
        // Everything else, including any category introduced since, is on.
        for category in RuleCategory.allCases where category != .git {
            #expect(decoded.promptRuleCategories.contains(category), "\(category) arrived off")
        }
    }

    @Test("switching one off leaves the rest on")
    func deselectionRoundTrips() throws {
        var settings = CaptionSettings()
        settings.promptRuleCategories = Set(RuleCategory.allCases).subtracting([.performance])
        let decoded = try JSONDecoder().decode(
            CaptionSettings.self, from: JSONEncoder().encode(settings)
        )
        #expect(decoded.promptRuleCategories == Set(RuleCategory.allCases).subtracting([.performance]))
    }
}

/// Two resets, not one. The features are independent, so fixing one should
/// never cost the other.
@Suite("Per-feature reset")
struct SettingsResetTests {

    private func customised() -> CaptionSettings {
        var s = CaptionSettings()
        s.firstLanguage = "ja-JP"
        s.overlayFontSize = 22
        s.diarizationEnabled = false
        s.promptLayout = .codexMarkdown
        s.promptOutputLanguage = .traditionalChinese
        s.promptTargetProjectPath = "/tmp/project"
        s.promptRuleCategories = [.coding]
        return s
    }

    @Test("resetting captions leaves the prompt settings alone")
    func captionResetKeepsPromptSettings() {
        var s = customised()
        s.resetCaptionSettings()
        #expect(s.firstLanguage == CaptionSettings().firstLanguage)
        #expect(s.overlayFontSize == CaptionSettings().overlayFontSize)
        #expect(s.diarizationEnabled == CaptionSettings().diarizationEnabled)
        // Untouched.
        #expect(s.promptLayout == .codexMarkdown)
        #expect(s.promptOutputLanguage == .traditionalChinese)
        #expect(s.promptTargetProjectPath == "/tmp/project")
        #expect(s.promptRuleCategories == [.coding])
    }

    @Test("resetting the prompt settings leaves the captions alone")
    func promptResetKeepsCaptionSettings() {
        var s = customised()
        s.resetPromptSettings()
        #expect(s.promptLayout == CaptionSettings().promptLayout)
        #expect(s.promptOutputLanguage == CaptionSettings().promptOutputLanguage)
        #expect(s.promptTargetProjectPath == nil)
        #expect(s.promptRuleCategories == Set(RuleCategory.allCases))
        // Untouched.
        #expect(s.firstLanguage == "ja-JP")
        #expect(s.overlayFontSize == 22)
        #expect(!s.diarizationEnabled)
    }

    @Test("both resets together give a fresh install")
    func bothResetsGiveDefaults() {
        var s = customised()
        s.resetCaptionSettings()
        s.resetPromptSettings()
        #expect(s == CaptionSettings())
    }
}

/// `zh-TW` was a selectable recognition language until the model's own
/// `tokenizer.json` was checked: every shipped variant has `<zh-CN>` and none has
/// `<zh-TW>`, so the language lock searched for a tag that does not exist and the
/// decoder produced garbage.
@Suite struct MandarinRecognitionLocaleTests {

    @Test func onlyTheTagTheModelHasIsOffered() {
        let codes = (SupportedASRLanguages.transcriptionReady
            + SupportedASRLanguages.broadCoverage).map(\.code)
        #expect(codes.contains("zh-CN"))
        #expect(!codes.contains("zh-TW"))
    }

    @Test func aStoredSelectionIsMigrated() {
        let json = Data(#"{"firstLanguage":"zh-TW"}"#.utf8)
        let settings = try? JSONDecoder().decode(CaptionSettings.self, from: json)
        #expect(settings?.firstLanguage == "zh-CN")
    }

    @Test func otherLanguagesAreUntouched() {
        let json = Data(#"{"firstLanguage":"ja-JP"}"#.utf8)
        #expect((try? JSONDecoder().decode(CaptionSettings.self, from: json))?
            .firstLanguage == "ja-JP")
    }

    /// Removing the locale must not remove Traditional output — the script guard
    /// is what produces it, and it is now on the caption path too.
    @Test func simplifiedRecognitionBecomesTraditional() {
        #expect(TraditionalChineseGuard.normalizingScript("这个程式码有问题")
            == "這個程式碼有問題")
    }
}
