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
    /// finalized line — it used to be dimmed too, which made the live sentence
    /// the faintest thing on screen and flashed it brighter the instant it
    /// ended. The raw value keeps the old spelling so persisted settings decode.
    case markedWithCaret = "dimmedWithCaret"
    /// Don't show the interim line at all (only finalized units).
    case hidden
}

/// Caption presentation and pipeline preferences (data-model.md: CaptionSettings).
public struct CaptionSettings: Codable, Sendable, Equatable {
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
    /// recorded transcript. Off by default: it keeps the ~2.5 GB model resident
    /// for the whole meeting even when Apple handles translation.
    public var transcriptCorrectionEnabled: Bool

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
    /// Persisted overlay **top-centre anchor** in screen coordinates (the window's
    /// top edge / horizontal centre); nil = default (bottom-centre). Stored as a
    /// plain point so it survives relaunches; the overlay grows downward from it.
    public var overlayPosition: CGPoint?
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
        transcriptCorrectionEnabled: Bool = false,
        keepAcousticContext: Bool = false,
        systemInputGainDb: Double = 0,
        micInputGainDb: Double = 0,
        autoGainEnabled: Bool = false,
        scenario: CaptureScenario = .video,
        primaryLineOnTop: PrimaryLine = .original,
        historyLineCount: Int = 1,
        interimStyle: InterimStyle = .markedWithCaret,
        overlayOpacity: Double = 0.66,
        overlayFontSize: Double = 16,
        overlayPosition: CGPoint? = nil,
        autoCloseOverlayOnStop: Bool = false
    ) {
        self.firstLanguage = firstLanguage
        self.secondCaptionEnabled = secondCaptionEnabled
        self.secondLanguage = secondLanguage
        self.translationEngine = translationEngine
        self.clickThrough = clickThrough
        self.asrTier = asrTier
        self.diarizationEnabled = diarizationEnabled
        self.transcriptCorrectionEnabled = transcriptCorrectionEnabled
        self.keepAcousticContext = keepAcousticContext
        self.systemInputGainDb = CaptionSettings.clampGain(systemInputGainDb)
        self.micInputGainDb = CaptionSettings.clampGain(micInputGainDb)
        self.autoGainEnabled = autoGainEnabled
        self.scenario = scenario
        self.primaryLineOnTop = primaryLineOnTop
        self.historyLineCount = max(0, min(2, historyLineCount))
        self.interimStyle = interimStyle
        self.overlayOpacity = overlayOpacity
        self.overlayFontSize = overlayFontSize
        self.overlayPosition = overlayPosition
        self.autoCloseOverlayOnStop = autoCloseOverlayOnStop
    }

    /// Tolerant decode: every field falls back to its default when absent, so an
    /// older persisted JSON (which lacks the redesign's overlay keys, and had the
    /// now-removed `fontSize`/`position`/`opacity`) upgrades cleanly instead of
    /// resetting the whole settings object.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionSettings.default
        firstLanguage = try c.decodeIfPresent(String.self, forKey: .firstLanguage) ?? d.firstLanguage
        secondCaptionEnabled = try c.decodeIfPresent(Bool.self, forKey: .secondCaptionEnabled) ?? d.secondCaptionEnabled
        secondLanguage = try c.decodeIfPresent(SecondCaptionLanguage.self, forKey: .secondLanguage) ?? d.secondLanguage
        translationEngine = try c.decodeIfPresent(TranslationEngine.self, forKey: .translationEngine) ?? d.translationEngine
        clickThrough = try c.decodeIfPresent(Bool.self, forKey: .clickThrough) ?? d.clickThrough
        asrTier = try c.decodeIfPresent(String.self, forKey: .asrTier) ?? d.asrTier
        diarizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .diarizationEnabled) ?? d.diarizationEnabled
        transcriptCorrectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .transcriptCorrectionEnabled) ?? d.transcriptCorrectionEnabled
        keepAcousticContext = try c.decodeIfPresent(Bool.self, forKey: .keepAcousticContext) ?? d.keepAcousticContext
        systemInputGainDb = CaptionSettings.clampGain(try c.decodeIfPresent(Double.self, forKey: .systemInputGainDb) ?? d.systemInputGainDb)
        micInputGainDb = CaptionSettings.clampGain(try c.decodeIfPresent(Double.self, forKey: .micInputGainDb) ?? d.micInputGainDb)
        autoGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoGainEnabled) ?? d.autoGainEnabled
        scenario = try c.decodeIfPresent(CaptureScenario.self, forKey: .scenario) ?? d.scenario
        primaryLineOnTop = try c.decodeIfPresent(PrimaryLine.self, forKey: .primaryLineOnTop) ?? d.primaryLineOnTop
        historyLineCount = max(0, min(2, try c.decodeIfPresent(Int.self, forKey: .historyLineCount) ?? d.historyLineCount))
        interimStyle = try c.decodeIfPresent(InterimStyle.self, forKey: .interimStyle) ?? d.interimStyle
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? d.overlayOpacity
        overlayFontSize = try c.decodeIfPresent(Double.self, forKey: .overlayFontSize) ?? d.overlayFontSize
        overlayPosition = try c.decodeIfPresent(CGPoint.self, forKey: .overlayPosition) ?? d.overlayPosition
        autoCloseOverlayOnStop = try c.decodeIfPresent(Bool.self, forKey: .autoCloseOverlayOnStop) ?? d.autoCloseOverlayOnStop
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

    /// Whether the recognition language already produces Traditional characters.
    var sourceIsTraditionalChinese: Bool {
        let c = firstLanguage.lowercased()
        return c.hasSuffix("-tw") || c.hasSuffix("-hk") || c.contains("hant")
    }

    public static let `default` = CaptionSettings()
}
