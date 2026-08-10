import Foundation
import Testing
@testable import FlowTranslateCore

/// The engine choice is stored on one machine and may be read on another — a
/// synced settings file, a restored backup, a downgrade. The resolution rule has
/// to hold in every one of those cases, so it lives in the model and is asserted
/// here rather than being spelled `#available` at each call site.
@Suite("Dictation engine choice")
struct DictationEngineChoiceTests {

    @Test("automatic follows the system")
    func automaticFollowsTheSystem() {
        #expect(DictationEngineChoice.automatic.resolved(builtInAvailable: true) == .appleSpeech)
        #expect(DictationEngineChoice.automatic.resolved(builtInAvailable: false) == .nemotron)
    }

    @Test("an explicit Nemotron choice is honoured on every system")
    func explicitNemotronIsHonoured() {
        #expect(DictationEngineChoice.nemotron.resolved(builtInAvailable: true) == .nemotron)
        #expect(DictationEngineChoice.nemotron.resolved(builtInAvailable: false) == .nemotron)
    }

    /// The case a settings file carried from a newer machine: below macOS 26
    /// there is no built-in recognizer to fall back *from*, so the stored value
    /// must not strand dictation on an engine that does not exist.
    @Test("a stored built-in choice degrades to Nemotron where it is unavailable")
    func storedAppleChoiceDegrades() {
        #expect(DictationEngineChoice.appleSpeech.resolved(builtInAvailable: true) == .appleSpeech)
        #expect(DictationEngineChoice.appleSpeech.resolved(builtInAvailable: false) == .nemotron)
    }

    @Test("the default is automatic, and it survives a settings round trip")
    func defaultIsAutomatic() throws {
        #expect(CaptionSettings().promptDictationEngine == .automatic)
        var settings = CaptionSettings()
        settings.promptDictationEngine = .appleSpeech
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: data)
        #expect(decoded.promptDictationEngine == .appleSpeech)
    }

    /// An older settings file has no such key at all.
    @Test("a settings file written before the engine existed decodes to automatic")
    func absentKeyDecodesToAutomatic() throws {
        let json = #"{"firstLanguage":"en-US"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: json)
        #expect(decoded.promptDictationEngine == .automatic)
    }

    /// An unrecognised value must not fail the whole decode — that would reset
    /// every other setting the user has.
    @Test("an unknown engine value falls back without losing the rest")
    func unknownValueFallsBack() throws {
        let json = #"{"firstLanguage":"ja-JP","promptDictationEngine":"whisper"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: json)
        #expect(decoded.promptDictationEngine == .automatic)
        #expect(decoded.firstLanguage == "ja-JP")
    }

    /// Resetting the prompt half restores it; resetting the caption half must not
    /// touch it.
    @Test("the engine belongs to the prompt half of the settings")
    func engineBelongsToThePromptHalf() {
        var settings = CaptionSettings()
        settings.promptDictationEngine = .nemotron
        var captionsReset = settings
        captionsReset.resetCaptionSettings()
        #expect(captionsReset.promptDictationEngine == .nemotron)
        var promptReset = settings
        promptReset.resetPromptSettings()
        #expect(promptReset.promptDictationEngine == .automatic)
    }
}
