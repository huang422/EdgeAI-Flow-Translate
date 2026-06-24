import Foundation

/// Caption presentation and pipeline preferences (data-model.md: CaptionSettings).
public struct CaptionSettings: Codable, Sendable, Equatable {
    /// First caption (ASR) recognition language, a Nemotron locale code (e.g. "en-US").
    public var firstLanguage: String
    /// Whether the second caption (translation) is enabled.
    public var secondCaptionEnabled: Bool
    /// Second caption (translation) target language: Traditional Chinese or English.
    public var secondLanguage: SecondCaptionLanguage
    public var audioSources: Set<AudioSourceType>
    public var fontSize: Double
    public var position: CaptionPosition
    public var opacity: Double
    public var clickThrough: Bool
    public var asrTier: String
    public var diarizationEnabled: Bool

    public init(
        firstLanguage: String = SupportedASRLanguages.default,
        secondCaptionEnabled: Bool = true,
        secondLanguage: SecondCaptionLanguage = .traditionalChinese,
        audioSources: Set<AudioSourceType> = [.system],
        fontSize: Double = 16,
        position: CaptionPosition = .bottom,
        opacity: Double = 0.85,
        clickThrough: Bool = true,
        asrTier: String = "560ms",
        diarizationEnabled: Bool = false
    ) {
        self.firstLanguage = firstLanguage
        self.secondCaptionEnabled = secondCaptionEnabled
        self.secondLanguage = secondLanguage
        self.audioSources = audioSources
        self.fontSize = fontSize
        self.position = position
        self.opacity = opacity
        self.clickThrough = clickThrough
        self.asrTier = asrTier
        self.diarizationEnabled = diarizationEnabled
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
