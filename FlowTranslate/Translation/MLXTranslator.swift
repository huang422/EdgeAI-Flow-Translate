import Foundation

/// On-device sentence translator backed by the shared **Qwen3-4B-Instruct-2507** (4-bit) model
/// (`QwenModelHost`). Used when the first caption is "auto" (Apple can't
/// auto-detect a source) or when Apple's Translation framework doesn't support the
/// chosen language pair.
///
/// Holds no model of its own — it reuses the single `QwenModelHost` instance shared
/// with the meeting summarizer, so translation never adds a second copy of the model
/// to memory. The Instruct-2507 model is non-thinking, so each call is a single
/// low-latency generation.
final class MLXTranslator {
    private let host: QwenModelHost

    init(host: QwenModelHost) { self.host = host }

    /// Translate one sentence into `target` (the currently selected second-caption
    /// language, e.g. "English" or "繁體中文（台灣正體字…）"). The model itself is
    /// instructed to emit exactly that language — no post-processing. Optionally a
    /// few preceding source sentences are passed as `context` so the model can
    /// resolve pronouns/terms across the conversation without translating them.
    /// Returns nil on failure.
    func translate(_ text: String, target: String, context: [String] = []) async -> String? {
        // Enforce the selected target language through the model itself (strict
        // prompt + low temperature) — no post-hoc character conversion.
        let system = """
        You are a professional real-time subtitle translator. Translate into \(target).
        Rules:
        - Output ONLY the translation in \(target). No quotes, no notes, no romanization or \
        pinyin, no original text, no explanations.
        - Keep it natural, fluent and faithful; preserve names, numbers and technical terms.
        - Translate ONLY the text after "Line:". Lines after "Context:" are earlier subtitles \
        for reference only — never translate, repeat or mention them.
        - If the line is already in \(target), return it unchanged.
        """
        let recent = context.suffix(2).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let user = recent.isEmpty
            ? "Line: \(text)"
            : "Context:\n" + recent.joined(separator: "\n") + "\n\nLine: \(text)"
        // Qwen3-4B-Instruct-2507 is non-thinking by default — no `/no_think` token needed.
        // A mild repetition penalty guards the 4-bit model against word-loops.
        guard let output = await host.generate(
            system: system, user: user, maxTokens: 256,
            temperature: 0.2, topP: 0.9, repetitionPenalty: 1.1
        ) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
