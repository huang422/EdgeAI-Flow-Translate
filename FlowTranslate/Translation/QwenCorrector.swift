import Foundation
import FlowTranslateCore

/// Generative error correction (GER) for the **recorded** transcript, backed by
/// the same shared **Qwen3-4B-Instruct-2507** (4-bit) model as translation and
/// summarization (`QwenModelHost`) — so enabling it adds no second copy of the
/// model to memory.
///
/// GER (HyPoradise, NeurIPS 2023; RobustGER, ICLR 2024) reliably repairs
/// homophones, proper nouns and punctuation that a streaming ASR gets wrong.
/// Its documented failure mode is the LLM paraphrasing — or inventing — text
/// that was already correct, so every result is checked by
/// `TranscriptCorrectionGate` before it is allowed to replace anything.
///
/// **This never touches the live captions.** The floating overlay keeps the raw
/// ASR text it already showed; corrections only reach the transcript window,
/// the stored session, the summary and the exports. A caption that has already
/// scrolled past must not be rewritten under the reader's eyes.
final class QwenCorrector {
    private let host: QwenModelHost

    init(host: QwenModelHost) { self.host = host }

    /// Repair one finalized sentence, or return nil to keep the original.
    ///
    /// `context` carries the sentences around this one so recurring names stay
    /// consistent. It is prompt conditioning only — the model can't reach the
    /// acoustic decoder (the Nemotron streaming path exposes no contextual
    /// biasing), so everything here acts on the text after recognition.
    func correct(_ text: String, context: [String] = []) async -> String? {
        // The queue applies this too, so a too-short sentence never costs a slot;
        // repeating it here means the corrector can't be misused into burning a
        // generation on "Okay." The rule itself lives in exactly one place.
        guard TranscriptCorrectionGate.shouldAttempt(text) else { return nil }
        guard let output = await host.generate(
            system: Self.systemPrompt,
            user: Self.userPrompt(text, context: context),
            maxTokens: Self.tokenCap(for: text),
            temperature: 0.1, topP: 0.9, repetitionPenalty: 1.05
        ) else { return nil }

        let candidate = TranscriptCorrectionGate.sanitize(output)
        guard TranscriptCorrectionGate.accepts(original: text, corrected: candidate)
        else { return nil }
        return candidate
    }

    /// Output cap just above the input's own length: a repair is the same
    /// sentence, so anything materially longer is a runaway generation the gate's
    /// length check would throw away regardless.
    ///
    /// Measured in **estimated tokens**, not in `SpokenTextMetrics.units`. This is
    /// the same defect `PromptTextRepairer.tokenCap` was fixed for and it was
    /// never back-ported here, which is why AI transcript correction looked like
    /// it did nothing on Chinese while working on English:
    ///
    /// A 40-character Chinese line is ~32 estimated tokens but only 13 `units`,
    /// and `units * 3` gave it 39 → clamped to the floor of 48. Forty-eight tokens
    /// is barely enough to echo the line back and nothing more, so any leading
    /// space, quote or label pushed the real answer past the cap; the truncated
    /// result then failed the gate's length-ratio or edit-distance rule and was
    /// discarded. Every Chinese sentence, every time — indistinguishable from the
    /// feature being switched off.
    ///
    /// English was unaffected because `units` counts its words directly, so a
    /// 15-word sentence already got a cap of 90 for a ~20-token answer.
    static func tokenCap(for text: String) -> Int {
        min(256, max(64, TokenEstimator.estimate(text) * 2))
    }

    // MARK: - Prompts

    /// Deliberately negative-heavy: the job is repair, and every instruction here
    /// exists to stop the model doing something more interesting than that.
    ///
    /// The Traditional-Chinese rule is the one both dictation prompts have had
    /// from the start and this one did not. "Write it in the SAME language" is
    /// *satisfied* by Simplified — they are one language — so the instruction as
    /// written permitted precisely the drift this model is most prone to, and
    /// `TranscriptCorrectionGate` had no check to catch it either. A Chinese
    /// meeting with correction on could have its recorded transcript converted
    /// sentence by sentence, and the transcript is what the summary and every
    /// export are built from.
    static let systemPrompt = """
        You repair the raw output of a speech recognizer. The line after "Line:" \
        is what the recognizer heard.
        Rules:
        - Output ONLY the repaired line. No quotes, labels, notes or explanations.
        - Write it in the SAME language as the input. Never translate.
        - If the input is Chinese, write Traditional Chinese as used in Taiwan \
        (台灣正體中文). NEVER output Simplified characters — 简体字 is wrong output \
        here even though it is the same language.
        - Fix ONLY mis-heard words, names and punctuation/capitalization.
        - NEVER rephrase, summarize, shorten, expand or complete the sentence.
        - NEVER change any number, date or unit.
        - The speaker may be mid-thought; leave an unfinished sentence unfinished.
        - If nothing is clearly wrong, return the line exactly as given.
        - "Context:" is the surrounding transcript, for reference only — never repeat it.
        """

    /// Nearby sentences first (they carry the recurring names), then the line.
    static func userPrompt(_ text: String, context: [String]) -> String {
        let recent = context.suffix(2).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !recent.isEmpty else { return "Line: \(text)" }
        let block = recent.map { "- \($0)" }.joined(separator: "\n")
        return "Context:\n\(block)\n\nLine: \(text)"
    }
}
