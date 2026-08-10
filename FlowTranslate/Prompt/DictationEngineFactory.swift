import Foundation
import FlowTranslateCore

/// Decides which recognizer a dictation runs on, and builds it.
///
/// One place, because the answer has three inputs that are easy to disagree
/// about: the user's setting, whether the running system has the built-in
/// recognizer at all, and whether its assets exist for any locale. Every caller
/// asks here rather than checking `#available` itself.
@MainActor
enum DictationEngineFactory {

    /// Whether macOS 26's `DictationTranscriber` can be used on this machine.
    ///
    /// Cached after the first answer: it costs an async round trip into the
    /// Speech framework, the UI reads it while drawing a picker, and it cannot
    /// change without a reboot.
    private static var cachedAvailability: Bool?

    static func refreshAvailability() async {
        if #available(macOS 26.0, *) {
            cachedAvailability = await AppleDictationEngine.isAvailable()
        } else {
            cachedAvailability = false
        }
    }

    /// The last known answer. `false` until `refreshAvailability()` has run,
    /// which is deliberate: assuming the built-in recognizer exists and finding
    /// out it does not, mid-dictation, is worse than starting on Nemotron.
    ///
    /// It answers two questions that turn out to be the same one: whether a
    /// dictation *can* run on the built-in engine, and whether the picker should
    /// present that row as usable.
    static var builtInAvailable: Bool { cachedAvailability ?? false }

    static func resolved(_ settings: CaptionSettings) -> ResolvedDictationEngine {
        settings.promptDictationEngine.resolved(builtInAvailable: builtInAvailable)
    }

    /// Build the engine for one session.
    ///
    /// `asr` and `tier` are only used by the Nemotron path; the built-in engine
    /// needs neither, which is the point of the split.
    static func make(
        for settings: CaptionSettings,
        asr: NemotronStreamingService,
        tier: String
    ) -> DictationEngine {
        switch resolved(settings) {
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleDictationEngine()
            }
            // Unreachable — `resolved` cannot answer `.appleSpeech` unless
            // `refreshAvailability` found the framework — but falling back beats
            // trapping if that ever stops being true.
            return NemotronDictationEngine(asr: asr, tier: tier)
        case .nemotron:
            return NemotronDictationEngine(asr: asr, tier: tier)
        }
    }

    /// The dictation languages to offer, for whichever engine is in use.
    ///
    /// **The same three rows either way**, and that is deliberate. The built-in
    /// recognizer supports roughly the languages Apple ships Siri in — dozens of
    /// them — and offering that list here bought nothing: this app writes
    /// Traditional Chinese and English, the translation, the tidy pass, the
    /// script guard and the rulebook are all built for exactly those two, and a
    /// third language recognized correctly would then be repaired by a Qwen
    /// prompt that has never been asked to keep it.
    ///
    /// It also cost something real. The two engines had two different code sets
    /// (`zh-CN` for Nemotron, `zh-TW` for Apple), so switching engine left the
    /// stored value matching no row — and `refreshDictationLanguages` then
    /// "repaired" it to whatever sorted first in a fifty-entry list. One set of
    /// codes for both engines is what stops that; where a code has to differ for
    /// the model's sake, `PromptDictation.language(for:engine:)` translates it at
    /// the point of use, which is the one place that knows the engine.
    ///
    /// Only `installed` differs between the engines, because only the built-in
    /// one can answer it per language.
    static func availableLanguages(for settings: CaptionSettings) async -> [DictationLanguage] {
        switch resolved(settings) {
        case .nemotron:
            return DictationLanguage.options
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                // **No 混說 row.** `DictationTranscriber` takes exactly one locale
                // for a whole session — the SDK offers no multi-locale form — so
                // the option could never do what its name says here. It resolved
                // to the Mac's interface language instead, silently, as the
                // default, which is the single largest thing that made this engine
                // recognize worse than the system's own dictation. An option that
                // cannot be honoured is worse than one option fewer.
                let offered = DictationLanguage.options.filter { $0.code != "auto" }
                let installed = await AppleDictationEngine.installedLanguages(
                    among: offered.map(\.code))
                return offered.map { option in
                    var row = option
                    row.installed = installed.contains(option.code)
                    return row
                }
            }
            return DictationLanguage.options
        }
    }
}

/// One row in the dictation-language picker.
struct DictationLanguage: Identifiable, Hashable {
    let code: String
    let displayName: String
    /// Whether the engine already has this language on disk. Nemotron's own
    /// per-variant check lives elsewhere, so its rows report `true` and let the
    /// existing "needs a ~600 MB download" hint speak for them.
    var installed: Bool = true

    var id: String { code }

    /// The two languages this app is written for, plus mixed speech — one list
    /// for both engines.
    ///
    /// `zh-TW` is the stored code even though no Nemotron variant carries that
    /// tag: it is what the user actually picked, and the built-in recognizer
    /// takes it verbatim. `PromptDictation.language(for:engine:)` rewrites it to
    /// `zh-CN` for Nemotron, whose only Mandarin ship is the Simplified one, and
    /// `TraditionalChineseGuard` normalizes the script afterwards.
    /// Labelled `中文 English`, the form every control in this app uses.
    static let options: [DictationLanguage] = [
        DictationLanguage(code: "zh-TW", displayName: "中文 Chinese"),
        DictationLanguage(code: "en-US", displayName: "英文 English"),
        DictationLanguage(code: "auto", displayName: "混說 Mixed"),
    ]
}
