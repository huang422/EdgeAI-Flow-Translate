import Foundation

/// A single language/locale option for the first caption.
public struct LanguageLocale: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String { code }      // BCP-47 / Nemotron locale, e.g. "en-US"
    public let code: String
    public let displayName: String      // Display name (Traditional Chinese)

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }
}

/// First-caption (ASR) recognition languages, served by the multilingual
/// Nemotron‑3.5 model via a `setLanguage(code)` hint (or `"auto"` for
/// per-sentence detection / mixed-language audio).
/// Source: languages supported by nvidia/nemotron-3.5-asr-streaming-0.6b.
public enum SupportedASRLanguages {
    /// Default first-caption language.
    public static let `default` = "en-US"

    /// Transcription-ready (19 locales) — best recognition quality.
    public static let transcriptionReady: [LanguageLocale] = [
        .init(code: "en-US", displayName: "英文 (美國)"),
        .init(code: "en-GB", displayName: "英文 (英國)"),
        .init(code: "es-US", displayName: "西班牙文 (美洲)"),
        .init(code: "es-ES", displayName: "西班牙文 (西班牙)"),
        .init(code: "fr-FR", displayName: "法文 (法國)"),
        .init(code: "fr-CA", displayName: "法文 (加拿大)"),
        .init(code: "it-IT", displayName: "義大利文"),
        .init(code: "pt-BR", displayName: "葡萄牙文 (巴西)"),
        .init(code: "pt-PT", displayName: "葡萄牙文 (葡萄牙)"),
        .init(code: "nl-NL", displayName: "荷蘭文"),
        .init(code: "de-DE", displayName: "德文"),
        .init(code: "tr-TR", displayName: "土耳其文"),
        .init(code: "ru-RU", displayName: "俄文"),
        .init(code: "ar-AR", displayName: "阿拉伯文"),
        .init(code: "hi-IN", displayName: "印地文"),
        .init(code: "ja-JP", displayName: "日文"),
        .init(code: "ko-KR", displayName: "韓文"),
        .init(code: "vi-VN", displayName: "越南文"),
        .init(code: "uk-UA", displayName: "烏克蘭文"),
    ]

    /// Broad-coverage (13 locales) — usable recognition quality.
    public static let broadCoverage: [LanguageLocale] = [
        .init(code: "pl-PL", displayName: "波蘭文"),
        .init(code: "sv-SE", displayName: "瑞典文"),
        .init(code: "cs-CZ", displayName: "捷克文"),
        .init(code: "nb-NO", displayName: "挪威文 (Bokmål)"),
        .init(code: "da-DK", displayName: "丹麥文"),
        .init(code: "bg-BG", displayName: "保加利亞文"),
        .init(code: "fi-FI", displayName: "芬蘭文"),
        .init(code: "hr-HR", displayName: "克羅埃西亞文"),
        .init(code: "sk-SK", displayName: "斯洛伐克文"),
        .init(code: "zh-CN", displayName: "中文 (簡體/普通話)"),
        .init(code: "hu-HU", displayName: "匈牙利文"),
        .init(code: "ro-RO", displayName: "羅馬尼亞文"),
        .init(code: "et-EE", displayName: "愛沙尼亞文"),
    ]

    /// All directly transcribable languages (32 locales).
    public static var all: [LanguageLocale] { transcriptionReady + broadCoverage }

    public static func locale(for code: String) -> LanguageLocale? {
        all.first { $0.code == code }
    }
}

/// Second-caption (translation) target languages. The second caption can be
/// turned off (see CaptionSettings.secondCaptionEnabled).
public enum SecondCaptionLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    /// Target-language phrasing fed to the translation model so it outputs exactly
    /// the selected second-caption language (with the strict script requirement
    /// for Traditional Chinese).
    public var modelTargetName: String {
        switch self {
        case .traditionalChinese: return "繁體中文（台灣正體字；必須使用繁體字，禁止使用任何簡體字）"
        case .english: return "English"
        }
    }
}
