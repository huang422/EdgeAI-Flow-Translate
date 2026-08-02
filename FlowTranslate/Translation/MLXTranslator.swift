import Foundation
import FlowTranslateCore

/// On-device sentence translator backed by the shared **Qwen3-4B-Instruct-2507** (4-bit) model
/// (`QwenModelHost`). Used when the first caption is "auto" (Apple can't
/// auto-detect a source), when Apple's Translation framework doesn't support the
/// chosen language pair, or when the user explicitly selects the Qwen engine.
///
/// Holds no model of its own — it reuses the single `QwenModelHost` instance shared
/// with the meeting summarizer, so translation never adds a second copy of the model
/// to memory. The Instruct-2507 model is non-thinking, so each call is a single
/// low-latency generation.
///
/// Quality levers (all cheap — a slightly longer prefill, no extra decode):
/// - A target-specific system prompt: the Traditional-Chinese one carries Taiwan
///   phrasing rules and two few-shot examples of "spoken ASR line → fluent subtitle".
/// - Bilingual rolling context (previous source→translation pairs) so terminology
///   and pronouns stay consistent across consecutive lines.
/// - `TraditionalChineseGuard` post-pass: converts rare Simplified-character
///   leakage (detected with zero false positives) and Mainland-only terms.
final class MLXTranslator {
    private let host: QwenModelHost

    init(host: QwenModelHost) { self.host = host }

    /// Translate one sentence into the selected second-caption language.
    /// `context` carries a few preceding source sentences with their translations
    /// (when already available) so the model can keep terms/pronouns consistent
    /// across the conversation without re-translating them. Returns nil on failure.
    func translate(
        _ text: String,
        target: SecondCaptionLanguage,
        context: [BilingualContextBuffer.Entry] = []
    ) async -> String? {
        let system = Self.systemPrompt(for: target)
        let user = Self.userPrompt(text, context: context)
        // Qwen3-4B-Instruct-2507 is non-thinking by default — no `/no_think` token needed.
        // A mild repetition penalty guards the 4-bit model against word-loops.
        // The token cap scales with the input so a (rare) runaway generation can
        // never stall the translation queue behind one sentence.
        guard let output = await host.generate(
            system: system, user: user, maxTokens: Self.tokenCap(for: text),
            temperature: 0.2, topP: 0.9, repetitionPenalty: 1.1
        ) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Safety net for the Traditional-Chinese target only (script + Taiwan terms).
        return target == .traditionalChinese ? TraditionalChineseGuard.polish(trimmed) : trimmed
    }

    /// Decode-length cap proportional to the input (subtitle sentences are short;
    /// a translation never legitimately needs more than ~6 tokens per source word).
    static func tokenCap(for text: String) -> Int {
        min(256, max(64, SpokenTextMetrics.units(text) * 6))
    }

    // MARK: - Prompts

    /// Target-specific system prompt. Enforced through the model (strict rules +
    /// low temperature); `TraditionalChineseGuard` covers the rare leftovers.
    /// Kept deliberately compact — the system prompt is re-prefilled on every
    /// sentence, so every extra token here costs real-time latency.
    static func systemPrompt(for target: SecondCaptionLanguage) -> String {
        switch target {
        case .traditionalChinese:
            return """
            You are a real-time subtitle translator. Translate the line after "Line:" into \
            Traditional Chinese as used in Taiwan (台灣正體中文).
            Rules:
            - Output ONLY the translation — no quotes, notes, pinyin, or the original text.
            - Traditional characters ONLY, never Simplified. Taiwan wording (軟體、網路、影片、\
            資料、伺服器、人工智慧) and full-width punctuation（，。？！）.
            - The line is live ASR speech: drop fillers (uh, um), fix obvious mis-hearings, \
            and write the fluent subtitle a native speaker would.
            - Keep names, numbers and units; keep common technical terms in English \
            (GitHub、API、bug).
            - "Context:" entries are earlier subtitles with translations — use them only to \
            keep terms and pronouns consistent; never translate or repeat them.
            - If the line is already Traditional Chinese, return it unchanged.
            Examples:
            Line: so um we're gonna ship the new dashboard uh next Tuesday
            → 我們下週二會推出新的儀表板。
            Line: it costs about three hundred dollars per user per month
            → 費用大約是每位使用者每月三百美元。
            """
        case .english:
            return """
            You are a real-time subtitle translator. Translate the line after "Line:" into English.
            Rules:
            - Output ONLY the English translation — no quotes, notes, romanization, or the \
            original text.
            - The line is live ASR speech: drop fillers, fix obvious mis-hearings, and write \
            the fluent subtitle a native speaker would.
            - Keep names, numbers, units and technical terms.
            - "Context:" entries are earlier subtitles with translations — use them only to \
            keep terms and pronouns consistent; never translate or repeat them.
            - If the line is already in English, return it unchanged.
            """
        }
    }

    /// The user message: optional bilingual context block, then the line to translate.
    static func userPrompt(_ text: String, context: [BilingualContextBuffer.Entry]) -> String {
        let recent = context.suffix(2).filter {
            !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !recent.isEmpty else { return "Line: \(text)" }
        let block = recent.map { entry -> String in
            if let translation = entry.translation, !translation.isEmpty {
                return "- \(entry.source)\n  → \(translation)"
            }
            return "- \(entry.source)"
        }.joined(separator: "\n")
        return "Context:\n\(block)\n\nLine: \(text)"
    }
}
