import Foundation
import CoreGraphics

/// Which language sits on the **top** (primary, brightest) line of a caption unit.
/// `.original` suits language learning / following the audio; `.translation` suits
/// reading meetings in your own language.
public enum PrimaryLine: String, Codable, Sendable, CaseIterable {
    case original, translation
}

/// Which backend translates the second caption when the first-caption language is
/// a specific (non-auto) one. With `auto` first caption the app always uses the
/// on-device Qwen model regardless of this setting (Apple can't auto-detect).
public enum TranslationEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple's on-device Translation framework when it supports the pair,
    /// falling back to the Qwen model otherwise (the historical behavior).
    case system
    /// Always the on-device MLX Qwen model.
    case qwen

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return "Apple 系統翻譯"
        case .qwen: return "Qwen 模型"
        }
    }
}

/// How the in-progress (interim) recognition line is drawn in the overlay.
public enum InterimStyle: String, Codable, Sendable, CaseIterable {
    /// A blinking caret + dotted underline + breathing dot mark the line as
    /// "still being recognized". The text itself is drawn exactly like every
    /// finalized line: dimming it as well makes the sentence being read the
    /// faintest thing on screen and flashes it brighter the instant it ends. The
    /// raw value keeps the old spelling so persisted settings decode.
    case markedWithCaret = "dimmedWithCaret"
    /// Don't show the interim line at all (only finalized units).
    case hidden
}

/// Caption presentation and pipeline preferences (data-model.md: CaptionSettings).
public struct CaptionSettings: Codable, Sendable, Equatable {

    /// Restore the caption half to its defaults, leaving the prompt half alone.
    ///
    /// Two resets rather than one, because the two features are independent and
    /// a single "reset everything" makes fixing one of them cost the other.
    public mutating func resetCaptionSettings() {
        var next = CaptionSettings()
        next.adoptPromptSettings(from: self)
        self = next
    }

    /// Restore the prompt half to its defaults, leaving the captions alone.
    public mutating func resetPromptSettings() {
        adoptPromptSettings(from: CaptionSettings())
    }

    /// Copy every prompt-half field from `other`.
    ///
    /// **One list, used by both resets.** They each carried their own copy of the
    /// same twelve field names, so adding a prompt setting meant remembering two
    /// places: miss the first and "reset caption settings" silently wipes the new
    /// field — the exact thing its doc promises not to do — and miss the second
    /// and "reset prompt settings" quietly leaves it behind. Adding
    /// `promptDictationEngine` had to touch both, which is how this got noticed.
    ///
    /// A compiler-enforced split (a nested `PromptSettings` struct) would be
    /// better still, but it changes the persisted JSON shape and every call site;
    /// this removes the drift between the two lists at no migration cost.
    private mutating func adoptPromptSettings(from other: CaptionSettings) {
        promptHotkeyEnabled = other.promptHotkeyEnabled
        promptDictationLanguage = other.promptDictationLanguage
        promptDictationEngine = other.promptDictationEngine
        promptOutputLanguage = other.promptOutputLanguage
        promptSymbolMode = other.promptSymbolMode
        promptLayout = other.promptLayout
        promptTargetProjectPath = other.promptTargetProjectPath
        promptQuickInsertMode = other.promptQuickInsertMode
        promptDetailLevel = other.promptDetailLevel
        promptHUDPosition = other.promptHUDPosition
        promptRuleCategoriesOff = other.promptRuleCategoriesOff
    }

    /// First caption (ASR) recognition language, a Nemotron locale code (e.g. "en-US").
    public var firstLanguage: String
    /// Whether the second caption (translation) is enabled.
    public var secondCaptionEnabled: Bool
    /// Second caption (translation) target language: Traditional Chinese or English.
    public var secondLanguage: SecondCaptionLanguage
    /// Which backend translates the second caption (see `TranslationEngine`).
    public var translationEngine: TranslationEngine
    public var clickThrough: Bool
    public var asrTier: String
    /// Optional speaker diarization (pyannote 3.1 + WeSpeaker via FluidAudio):
    /// labels speakers per audio source; applied on the next Start.
    public var diarizationEnabled: Bool
    /// How readily the diarizer splits one voice into two.
    ///
    /// A setting rather than a constant because the two ways diarization goes
    /// wrong need opposite corrections, and which one you hit depends on the
    /// room: two people on one microphone over-segment, five on a conference
    /// call under-segment. Applies on the next Start.
    public var diarizationSensitivity: DiarizationSensitivity

    /// **Experimental.** Keep the model's acoustic context across sentence
    /// boundaries instead of resetting it at every finalize. The encoder carries
    /// 3.36 s of left context (`att_context_size [42, 13]`) and the reset throws
    /// it away, so the first words of each sentence are recognized cold.
    ///
    /// Off by default because the same reset also re-seeds the language lock and
    /// clears the decoder state — keeping it may make the model continue the
    /// previous sentence rather than start a new one. There is no WER harness in
    /// this project, so this exists to be A/B'd on real speech.
    public var keepAcousticContext: Bool

    // MARK: Transcript correction (accurate track — never the live captions)

    /// Whether the on-device Qwen model repairs finalized sentences in the
    /// recorded transcript. Off by default: it keeps the ~2.3 GB model resident
    /// for the whole meeting even when Apple handles translation.
    public var transcriptCorrectionEnabled: Bool

    // MARK: Prompt Composer (the Prompt tab — shares models with captions, never runs alongside them)

    /// Whether ⌃⌥Space dictates from anywhere.
    ///
    /// The only switch the Prompt tab has. There was also a master
    /// `promptComposerEnabled` that hid the tab; it is gone. A primary feature
    /// should not have a control capable of making it disappear — that one
    /// removed the tab, the tab picker, and with them any way back, and the
    /// checkbox that did it was drawn on the tab it removed.
    ///
    /// The hotkey is a genuine choice, because a global shortcut fires in every
    /// application whether or not this one is in front.
    public var promptHotkeyEnabled: Bool
    /// Which language prompt dictation is spoken in: `"en-US"`, `"zh-TW"` or
    /// `"auto"` for code-switched speech.
    ///
    /// Deliberately independent of the captions language. They are different
    /// activities — you might caption an English meeting and dictate requests in
    /// Chinese — and a "follow the captions" option tied them together for no
    /// reason beyond saving a download that the hint already discloses.
    ///
    /// `"auto"` selects the multilingual weights, which is free when the
    /// captions language is already non-Latin and an extra ~600 MB variant when
    /// it is English.
    public var promptDictationLanguage: String
    /// Which recognizer dictation uses. See `DictationEngineChoice` — captions
    /// are deliberately not covered by it.
    public var promptDictationEngine: DictationEngineChoice
    /// Language of the *compiled prompt*, independent of what the user speaks.
    /// English by default because the same constraint costs roughly 30–50% more
    /// tokens in Chinese, and Claude follows English instructions most reliably.
    public var promptOutputLanguage: PromptOutputLanguage
    /// What the global dictation hotkey drops at the cursor.
    public var promptQuickInsertMode: PromptQuickInsertMode
    /// How many of the prompt's sections to print.
    ///
    /// A compiled prompt can carry ten sections, and not every request earns all
    /// ten: `risks` and `tools` in particular are usually the compiler inferring
    /// something the user never said, paid for at full price on every use.
    public var promptDetailLevel: PromptDetailLevel
    /// Where the dictation HUD was last dragged to, as the panel's bottom-left
    /// origin in screen coordinates. `nil` until the user moves it, and then it
    /// wins over the default placement beside the pointer — a status panel that
    /// reappears where you put it is the same affordance the caption band has.
    public var promptHUDPosition: CGPoint?
    /// Project folder that receives skills, commands and the rulebook. `nil`
    /// until the user picks one.
    public var promptTargetProjectPath: String?
    /// How rulebook symbols appear.
    ///
    /// Defaults to bare symbols — the cheapest mode — because it is now safe to:
    /// when the project has no synced rulebook the renderer falls back to
    /// writing each constraint out in full, which costs less than the old
    /// legend fallback did. So the default is the best available answer whether
    /// or not the user ever syncs anything, and syncing is a pure improvement
    /// rather than a prerequisite.
    public var promptSymbolMode: PromptSymbolMode
    /// `TASK:` labels or `## Markdown` headings for the plain prompt output.
    public var promptLayout: PromptLayout
    /// The rule categories the user has switched **off**.
    ///
    /// Stored negated, and read through `promptRuleCategories` below, which
    /// inverts it again. The polarity is what makes new categories arrive
    /// switched on: a settings file written by an older build lists only the
    /// categories that existed then, so a category added later is absent from the
    /// "off" set and is therefore on. Storing the enabled set instead would have
    /// the opposite effect — every new category would be silently missing from
    /// every existing install, and nothing in the UI says a rule was never
    /// offered. The custom decoder drops unrecognised names for the mirror-image
    /// reason: one unknown element must not fail the whole set and leave it
    /// unresolvable.
    public var promptRuleCategoriesOff: Set<RuleCategory>

    /// The categories that will be installed. Everything not switched off.
    public var promptRuleCategories: Set<RuleCategory> {
        get { Set(RuleCategory.allCases).subtracting(promptRuleCategoriesOff) }
        set { promptRuleCategoriesOff = Set(RuleCategory.allCases).subtracting(newValue) }
    }

    // MARK: Input gain (help a quiet meeting participant clear the level gates)

    /// Fixed boost applied to the **system** audio input before the ASR, in dB
    /// (0...30). 0 = off. Louder input lets soft speech pass the VAD / voiced gate.
    public var systemInputGainDb: Double
    /// Fixed boost applied to the **microphone** input before the ASR, in dB (0...30).
    public var micInputGainDb: Double
    /// When true, adaptively raise quiet speech toward a target loudness on top of
    /// the manual gains (upward compression, rate-limited + noise-gated + limited).
    public var autoGainEnabled: Bool
    /// What the system audio is (video vs. live meeting speech) — drives the
    /// utterance-segmentation timing (see `SegmentationTuning`).
    public var scenario: CaptureScenario

    // MARK: Overlay presentation (redesign)

    /// Which language is the top/primary line of each caption unit.
    public var primaryLineOnTop: PrimaryLine
    /// How many finalized sentences of history to keep on screen in addition to the
    /// current one (clamped 0...2 → shows "now + N").
    public var historyLineCount: Int
    /// Interim-line rendering style.
    public var interimStyle: InterimStyle
    /// Overlay scrim opacity (0.4...0.9).
    public var overlayOpacity: Double
    /// Overlay text size in points (12...22).
    public var overlayFontSize: Double
    /// Persisted overlay **bottom-centre anchor** in screen coordinates (the
    /// window's bottom edge / horizontal centre); nil = default placement.
    ///
    /// The bottom edge, because it is the only edge that holds still: the band
    /// grows upward from it, so the top moves and the bottom does not.
    ///
    /// **A new key, deliberately.** The old `overlayPosition` stored the
    /// *top*-centre point, and the two cannot be told apart by looking at them —
    /// so reading an old value under the new meaning silently placed the overlay
    /// about one box-height too high, close enough to the top of the screen that
    /// the "keep it on screen" clamp then moved the bottom edge on every resize.
    /// That is the opposite of what this field exists to guarantee. Ignoring the
    /// old key costs one re-drag; reinterpreting it cost a moving caption box.
    public var overlayBottomAnchor: CGPoint?
    /// When `true`, ending a meeting (Stop) also hides the floating overlay. Default
    /// `false`: the overlay stays put and just reflects the idle state, so the user
    /// keeps control of its visibility via the switch / ⌃⌥C.
    public var autoCloseOverlayOnStop: Bool

    public init(
        firstLanguage: String = SupportedASRLanguages.default,
        secondCaptionEnabled: Bool = true,
        secondLanguage: SecondCaptionLanguage = .traditionalChinese,
        translationEngine: TranslationEngine = .system,
        clickThrough: Bool = true,
        asrTier: String = "560ms",
        // On by default: knowing who said what is core to a meeting transcript,
        // and the labels flow into the summary and exports. Costs a ~60 MB model
        // and one pyannote inference per finalized sentence.
        diarizationEnabled: Bool = true,
        diarizationSensitivity: DiarizationSensitivity = .balanced,
        transcriptCorrectionEnabled: Bool = false,
        keepAcousticContext: Bool = false,
        promptHotkeyEnabled: Bool = true,
        promptDictationLanguage: String = "auto",
        promptDictationEngine: DictationEngineChoice = .automatic,
        promptOutputLanguage: PromptOutputLanguage = .english,
        promptQuickInsertMode: PromptQuickInsertMode = .tidiedTranscript,
        promptDetailLevel: PromptDetailLevel = .compact,
        promptHUDPosition: CGPoint? = nil,
        promptTargetProjectPath: String? = nil,
        promptSymbolMode: PromptSymbolMode = .symbolsAssumeRulebook,
        promptLayout: PromptLayout = .claudeXML,
        promptRuleCategoriesOff: Set<RuleCategory> = [],
        systemInputGainDb: Double = 0,
        micInputGainDb: Double = 0,
        autoGainEnabled: Bool = false,
        scenario: CaptureScenario = .video,
        primaryLineOnTop: PrimaryLine = .original,
        historyLineCount: Int = 1,
        interimStyle: InterimStyle = .markedWithCaret,
        overlayOpacity: Double = 0.66,
        overlayFontSize: Double = 16,
        overlayBottomAnchor: CGPoint? = nil,
        autoCloseOverlayOnStop: Bool = false
    ) {
        self.firstLanguage = firstLanguage
        self.secondCaptionEnabled = secondCaptionEnabled
        self.secondLanguage = secondLanguage
        self.translationEngine = translationEngine
        self.clickThrough = clickThrough
        self.asrTier = asrTier
        self.diarizationEnabled = diarizationEnabled
        self.diarizationSensitivity = diarizationSensitivity
        self.transcriptCorrectionEnabled = transcriptCorrectionEnabled
        self.keepAcousticContext = keepAcousticContext
        self.promptHotkeyEnabled = promptHotkeyEnabled
        self.promptDictationLanguage = promptDictationLanguage
        self.promptDictationEngine = promptDictationEngine
        self.promptOutputLanguage = promptOutputLanguage
        self.promptQuickInsertMode = promptQuickInsertMode
        self.promptDetailLevel = promptDetailLevel
        self.promptHUDPosition = promptHUDPosition
        self.promptTargetProjectPath = promptTargetProjectPath
        self.promptSymbolMode = promptSymbolMode
        self.promptLayout = promptLayout
        self.promptRuleCategoriesOff = promptRuleCategoriesOff
        self.systemInputGainDb = CaptionSettings.clampGain(systemInputGainDb)
        self.micInputGainDb = CaptionSettings.clampGain(micInputGainDb)
        self.autoGainEnabled = autoGainEnabled
        self.scenario = scenario
        self.primaryLineOnTop = primaryLineOnTop
        self.historyLineCount = max(0, min(2, historyLineCount))
        self.interimStyle = interimStyle
        self.overlayOpacity = overlayOpacity
        self.overlayFontSize = overlayFontSize
        self.overlayBottomAnchor = overlayBottomAnchor
        self.autoCloseOverlayOnStop = autoCloseOverlayOnStop
    }

    /// Tolerant decode: every field falls back to its default when absent, so an
    /// older persisted JSON (which lacks the redesign's overlay keys, and had the
    /// now-removed `fontSize`/`position`/`opacity`) upgrades cleanly instead of
    /// resetting the whole settings object.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionSettings.default
        // `zh-TW` was a selectable recognition language until it was found to
        // have no tag in any shipped model variant. Anyone who had chosen it is
        // moved to the tag the model does have; the Traditional output they
        // wanted comes from the script guard either way.
        let storedFirst = try c.decodeIfPresent(String.self, forKey: .firstLanguage)
            ?? d.firstLanguage
        firstLanguage = storedFirst == "zh-TW" ? "zh-CN" : storedFirst
        secondCaptionEnabled = try c.decodeIfPresent(Bool.self, forKey: .secondCaptionEnabled) ?? d.secondCaptionEnabled
        secondLanguage = Self.lenient(SecondCaptionLanguage.self, c, .secondLanguage, default: d.secondLanguage)
        translationEngine = Self.lenient(TranslationEngine.self, c, .translationEngine, default: d.translationEngine)
        clickThrough = try c.decodeIfPresent(Bool.self, forKey: .clickThrough) ?? d.clickThrough
        asrTier = try c.decodeIfPresent(String.self, forKey: .asrTier) ?? d.asrTier
        diarizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .diarizationEnabled) ?? d.diarizationEnabled
        diarizationSensitivity = Self.lenient(DiarizationSensitivity.self, c, .diarizationSensitivity, default: d.diarizationSensitivity)
        transcriptCorrectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .transcriptCorrectionEnabled) ?? d.transcriptCorrectionEnabled
        keepAcousticContext = try c.decodeIfPresent(Bool.self, forKey: .keepAcousticContext) ?? d.keepAcousticContext
        promptHotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .promptHotkeyEnabled) ?? d.promptHotkeyEnabled
        // `zh-CN` is a value from the builds where the dictation picker stored
        // Nemotron's *model* tag instead of the language the user chose. Both
        // engines now store `zh-TW` and the Nemotron tag is derived at the point
        // of use; migrating here rather than in the view means the setting is
        // already right for the hotkey, which never opens the Prompt tab.
        let storedDictationLanguage = try c.decodeIfPresent(
            String.self, forKey: .promptDictationLanguage) ?? d.promptDictationLanguage
        promptDictationLanguage = storedDictationLanguage == "zh-CN"
            ? "zh-TW" : storedDictationLanguage
        promptDictationEngine = Self.lenient(DictationEngineChoice.self, c, .promptDictationEngine, default: d.promptDictationEngine)
        promptOutputLanguage = Self.lenient(PromptOutputLanguage.self, c, .promptOutputLanguage, default: d.promptOutputLanguage)
        promptQuickInsertMode = Self.lenient(PromptQuickInsertMode.self, c, .promptQuickInsertMode, default: d.promptQuickInsertMode)
        promptDetailLevel = Self.lenient(PromptDetailLevel.self, c, .promptDetailLevel, default: d.promptDetailLevel)
        promptHUDPosition = try c.decodeIfPresent(CGPoint.self, forKey: .promptHUDPosition) ?? d.promptHUDPosition
        promptTargetProjectPath = try c.decodeIfPresent(String.self, forKey: .promptTargetProjectPath) ?? d.promptTargetProjectPath
        promptSymbolMode = Self.lenient(PromptSymbolMode.self, c, .promptSymbolMode, default: d.promptSymbolMode)
        promptLayout = Self.lenient(PromptLayout.self, c, .promptLayout, default: d.promptLayout)
        // Decoded through strings for the same reason as the enums above, and
        // one step further: an unrecognised *element* would fail the whole set,
        // so unknown categories are dropped and the recognised ones kept.
        promptRuleCategoriesOff = Set(
            ((try? c.decodeIfPresent([String].self, forKey: .promptRuleCategoriesOff)) ?? nil)?
                .compactMap(RuleCategory.init(rawValue:))
                ?? Array(d.promptRuleCategoriesOff)
        )
        systemInputGainDb = CaptionSettings.clampGain(try c.decodeIfPresent(Double.self, forKey: .systemInputGainDb) ?? d.systemInputGainDb)
        micInputGainDb = CaptionSettings.clampGain(try c.decodeIfPresent(Double.self, forKey: .micInputGainDb) ?? d.micInputGainDb)
        autoGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoGainEnabled) ?? d.autoGainEnabled
        scenario = Self.lenient(CaptureScenario.self, c, .scenario, default: d.scenario)
        primaryLineOnTop = Self.lenient(PrimaryLine.self, c, .primaryLineOnTop, default: d.primaryLineOnTop)
        historyLineCount = max(0, min(2, try c.decodeIfPresent(Int.self, forKey: .historyLineCount) ?? d.historyLineCount))
        interimStyle = Self.lenient(InterimStyle.self, c, .interimStyle, default: d.interimStyle)
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? d.overlayOpacity
        overlayFontSize = try c.decodeIfPresent(Double.self, forKey: .overlayFontSize) ?? d.overlayFontSize
        overlayBottomAnchor = try c.decodeIfPresent(CGPoint.self, forKey: .overlayBottomAnchor) ?? d.overlayBottomAnchor
        autoCloseOverlayOnStop = try c.decodeIfPresent(Bool.self, forKey: .autoCloseOverlayOnStop) ?? d.autoCloseOverlayOnStop
    }


    /// Decode a string-backed enum, falling back rather than failing.
    ///
    /// `decodeIfPresent` returns nil for an *absent* key but **throws** for a
    /// present one whose value no longer matches a case — and a throw here fails
    /// the whole `CaptionSettings` decode, resetting every setting the user has.
    /// That is exactly the outcome this initializer's tolerance was written to
    /// prevent, and it was one renamed case or one downgraded build away the
    /// whole time. Absent and unrecognised are the same situation: use the
    /// default for that one field and keep the rest.
    /// Generic over the key type rather than naming `CodingKeys`: this type's
    /// keys are synthesized, and a static member that names them in its signature
    /// blocks the compiler from inferring them at all.
    private static func lenient<T: RawRepresentable & Decodable, K: CodingKey>(
        _ type: T.Type,
        _ container: KeyedDecodingContainer<K>,
        _ key: K,
        default fallback: T
    ) -> T where T.RawValue == String {
        // Decoded through the type rather than through `init(rawValue:)`. A type
        // may migrate a retired case in its own `init(from:)` — `PromptSymbolMode`
        // maps the removed `expandInline` onto `off` — and going straight to the
        // raw value skipped that, silently moving those users to the app default
        // instead. Unknown values still throw and still land on `fallback`.
        // `try?` flattens the double optional, so a key that is absent and a key
        // that holds an unknown value both land on `fallback`.
        guard let decoded = try? container.decodeIfPresent(T.self, forKey: key) else {
            return fallback
        }
        return decoded
    }

    /// Upper bound for the input-gain sliders, matching the DSP cap (WebRTC `kMaxGainDb`).
    public static let maxInputGainDb: Double = 30

    /// Clamp a persisted/user gain into the valid `0...maxInputGainDb` range.
    static func clampGain(_ db: Double) -> Double { min(max(db, 0), maxInputGainDb) }

    /// Whether translation is required (enabled and the target differs from the source).
    public var needsTranslation: Bool {
        guard secondCaptionEnabled else { return false }
        let firstBase = String(firstLanguage.prefix(2)).lowercased()
        let secondBase = String(secondLanguage.rawValue.prefix(2)).lowercased()
        if firstBase != secondBase { return true }
        // Same base language (both Chinese): only a SIMPLIFIED source needs
        // converting to a Traditional target. Comparing the raw codes would
        // make `zh-TW` → `zh-Hant` look like a translation job and push every
        // already-Traditional sentence through the translator for nothing.
        if firstBase == "zh" {
            if secondLanguage == .traditionalChinese { return !sourceIsTraditionalChinese }
            return firstLanguage.lowercased() != secondLanguage.rawValue.lowercased()
        }
        return false
    }

    /// Whether the first caption is already Traditional by the time it is shown.
    ///
    /// True for **every** Mandarin recognition locale now, not just the ones
    /// whose code says `-tw`. The model has one Mandarin tag (`zh-CN`) and writes
    /// Simplified, and the caption path converts the script on the way through —
    /// so by the time a second caption would be produced, the first one is
    /// already Traditional and translating it would spend a generation
    /// reproducing its input.
    ///
    /// A locale suffix is still honoured for anything the model may add later.
    var sourceIsTraditionalChinese: Bool {
        let c = firstLanguage.lowercased()
        return c.hasPrefix("zh") || c.hasSuffix("-hk") || c.contains("hant")
    }

    public static let `default` = CaptionSettings()
}
