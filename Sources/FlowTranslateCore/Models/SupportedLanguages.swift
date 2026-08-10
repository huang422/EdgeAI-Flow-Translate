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
    ///
    /// This is the model's own quality grouping. What the picker shows is `all`,
    /// which reorders for the user rather than for the benchmark.
    public static let transcriptionReady: [LanguageLocale] = [
        .init(code: "en-US", displayName: "英文 (美國)"),
        .init(code: "en-GB", displayName: "英文 (英國)"),
        .init(code: "ja-JP", displayName: "日文"),
        .init(code: "ko-KR", displayName: "韓文"),
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
        .init(code: "vi-VN", displayName: "越南文"),
        .init(code: "uk-UA", displayName: "烏克蘭文"),
    ]

    /// Broad-coverage (13 locales) — usable recognition quality.
    ///
    /// Mandarin sits here on the model's own numbers: NVIDIA reports 19.3% CER
    /// for `zh-CN` against 7.9% WER for `en-US` at the same chunk size. See
    /// `promotedInPicker` for why it is still drawn near the top.
    public static let broadCoverage: [LanguageLocale] = [
        // One Mandarin entry, because the model has one.
        //
        // `zh-TW` was offered on the assumption that Nemotron prompts the two
        // locales separately. It does not: every shipped variant's
        // `tokenizer.json` contains `<zh-CN>` and no `<zh-TW>`, so selecting it
        // left the language lock searching for a tag that does not exist and the
        // decoder produced garbage. Recognition happens under the tag the model
        // has; Traditional output is produced afterwards by
        // `TraditionalChineseGuard`, which is where script conversion belongs.
        .init(code: "zh-CN", displayName: "中文 (中文/普通話)"),
        .init(code: "sv-SE", displayName: "瑞典文"),
        .init(code: "pl-PL", displayName: "波蘭文"),
        .init(code: "cs-CZ", displayName: "捷克文"),
        .init(code: "nb-NO", displayName: "挪威文 (Bokmål)"),
        .init(code: "da-DK", displayName: "丹麥文"),
        .init(code: "bg-BG", displayName: "保加利亞文"),
        .init(code: "fi-FI", displayName: "芬蘭文"),
        .init(code: "hr-HR", displayName: "克羅埃西亞文"),
        .init(code: "sk-SK", displayName: "斯洛伐克文"),
        .init(code: "hu-HU", displayName: "匈牙利文"),
        .init(code: "ro-RO", displayName: "羅馬尼亞文"),
        .init(code: "et-EE", displayName: "愛沙尼亞文"),
    ]

    /// Locales lifted to the top of the picker regardless of their quality tier.
    ///
    /// The tier lists say how well the model transcribes a language; the picker
    /// has to answer a different question — how likely is *this* user to pick it.
    /// Mandarin and Swedish sit in `broadCoverage`, so ordering by tier buried
    /// them under nineteen rows that get scrolled past every time.
    ///
    /// Order here is the requested one: 英文 · 中文 · 瑞典文 · 韓文 · 日文, then
    /// everything else in tier order.
    public static let promotedInPicker = ["zh-CN", "sv-SE", "ko-KR", "ja-JP"]

    /// All directly transcribable languages (32 locales), **in picker order**.
    ///
    /// English first, then the promoted pair directly under it, then everything
    /// else in tier order. The quality tiers stay exactly as they are — this
    /// changes where a row is drawn, never what the model is told.
    ///
    /// 32, not 33: `zh-TW` was removed once it turned out that no shipped model
    /// variant carries that tag. The counts and this ordering are asserted in
    /// `SupportedLanguagesTests`, so a future addition cannot leave them stale
    /// the way the count did.
    public static let all: [LanguageLocale] = {
        let tiered = transcriptionReady + broadCoverage
        let english = tiered.filter { $0.code.hasPrefix("en") }
        let promoted = promotedInPicker.compactMap { code in
            tiered.first { $0.code == code }
        }
        let rest = tiered.filter {
            !$0.code.hasPrefix("en") && !promotedInPicker.contains($0.code)
        }
        return english + promoted + rest
    }()

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
}
