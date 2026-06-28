import Foundation
import CoreGraphics

/// Which language sits on the **top** (primary, brightest) line of a caption unit.
/// `.original` suits language learning / following the audio; `.translation` suits
/// reading meetings in your own language.
public enum PrimaryLine: String, Codable, Sendable, CaseIterable {
    case original, translation
}

/// How the in-progress (interim) recognition line is drawn in the overlay.
public enum InterimStyle: String, Codable, Sendable, CaseIterable {
    /// Dimmed text with a blinking caret + dotted underline (a "still typing" cue).
    case dimmedWithCaret
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
    public var audioSources: Set<AudioSourceType>
    public var clickThrough: Bool
    public var asrTier: String
    public var diarizationEnabled: Bool

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
        audioSources: Set<AudioSourceType> = [.system],
        clickThrough: Bool = true,
        asrTier: String = "560ms",
        diarizationEnabled: Bool = false,
        primaryLineOnTop: PrimaryLine = .original,
        historyLineCount: Int = 1,
        interimStyle: InterimStyle = .dimmedWithCaret,
        overlayOpacity: Double = 0.66,
        overlayFontSize: Double = 16,
        overlayPosition: CGPoint? = nil,
        autoCloseOverlayOnStop: Bool = false
    ) {
        self.firstLanguage = firstLanguage
        self.secondCaptionEnabled = secondCaptionEnabled
        self.secondLanguage = secondLanguage
        self.audioSources = audioSources
        self.clickThrough = clickThrough
        self.asrTier = asrTier
        self.diarizationEnabled = diarizationEnabled
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
        audioSources = try c.decodeIfPresent(Set<AudioSourceType>.self, forKey: .audioSources) ?? d.audioSources
        clickThrough = try c.decodeIfPresent(Bool.self, forKey: .clickThrough) ?? d.clickThrough
        asrTier = try c.decodeIfPresent(String.self, forKey: .asrTier) ?? d.asrTier
        diarizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .diarizationEnabled) ?? d.diarizationEnabled
        primaryLineOnTop = try c.decodeIfPresent(PrimaryLine.self, forKey: .primaryLineOnTop) ?? d.primaryLineOnTop
        historyLineCount = max(0, min(2, try c.decodeIfPresent(Int.self, forKey: .historyLineCount) ?? d.historyLineCount))
        interimStyle = try c.decodeIfPresent(InterimStyle.self, forKey: .interimStyle) ?? d.interimStyle
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? d.overlayOpacity
        overlayFontSize = try c.decodeIfPresent(Double.self, forKey: .overlayFontSize) ?? d.overlayFontSize
        overlayPosition = try c.decodeIfPresent(CGPoint.self, forKey: .overlayPosition) ?? d.overlayPosition
        autoCloseOverlayOnStop = try c.decodeIfPresent(Bool.self, forKey: .autoCloseOverlayOnStop) ?? d.autoCloseOverlayOnStop
    }

    /// Whether translation is required (enabled and the target differs from the source).
    public var needsTranslation: Bool {
        guard secondCaptionEnabled else { return false }
        let firstBase = String(firstLanguage.prefix(2)).lowercased()
        let secondBase = String(secondLanguage.rawValue.prefix(2)).lowercased()
        if firstBase != secondBase { return true }
        // Same base language (e.g. both Chinese): still needs script conversion
        // when a simplified source maps to a traditional target.
        if firstBase == "zh" {
            return firstLanguage.lowercased() != secondLanguage.rawValue.lowercased()
        }
        return false
    }

    public static let `default` = CaptionSettings()
}
