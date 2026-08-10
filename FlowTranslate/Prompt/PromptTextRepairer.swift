import Foundation
import FlowTranslateCore

/// Repairs a request before it is compiled, whether it was spoken or typed.
///
/// Separate from `QwenCorrector` because that one's system prompt opens with
/// "You repair the raw output of a speech recognizer" — true for captions, and
/// actively misleading for text somebody typed. Told the input came from a
/// recognizer, the model looks for homophone mistakes that aren't there and
/// invents them; a typo is a different error class and needs a different
/// instruction.
///
/// Typing was previously skipped altogether: `tidyTranscript` guarded on
/// `origin.needsSpokenCleanup`, which is false for `.typed`, so the "整理"
/// button ran and did nothing. Filler removal genuinely is voice-only — a typed
/// "嗯" is deliberate — but typo repair and punctuation are not, and there was
/// never a reason to withhold them.
///
/// Holds no model: it borrows the shared `QwenModelHost`, like every other
/// generation path in the app.
final class PromptTextRepairer {
    /// Repetition-penalty window for a passage. Wide enough to see a loop whose
    /// period is a clause rather than a word.
    static let passageRepetitionWindow = 64

    /// Records the last streamed token count so the caller can tell a generation
    /// that finished from one that hit its cap. A class because the callback is
    /// `@Sendable` and fires off the MainActor.
    final class TokenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record(_ value: Int) { lock.withLock { count = max(count, value) } }
        var value: Int { lock.withLock { count } }
    }

    private let host: QwenModelHost

    init(host: QwenModelHost) { self.host = host }

    /// What happened to one line.
    ///
    /// Carries the reason rather than collapsing to `nil`, because "the repair
    /// was rejected" and "there was nothing to repair" look identical from the
    /// outside — which is exactly how a gate that quietly refused every repair
    /// could keep looking like a model that had nothing to fix.
    enum Outcome {
        case repaired(String)
        case unchanged
        case skipped
        case modelSilent
        case rejected(PromptRepairGate.Rejection)
    }

    /// What happened to a whole passage.
    enum PassageOutcome {
        case repaired(String)
        case unchanged
        case rejected(PassageRepairGate.Rejection)
        case modelSilent
    }

    /// Repair a whole dictated passage in **one** generation.
    ///
    /// The path `Tidied` and the compile step both take. Preferred over
    /// `repair(_:origin:context:)` for everything except the fallback:
    ///
    /// - **No error propagation.** A per-sentence loop feeds each call the
    ///   preceding *repaired* sentences — precisely the setup arXiv 2409.09785
    ///   measured raising word error rate. One pass reads the raw text and feeds
    ///   nothing back.
    /// - **Self-corrections become visible.** "週二兩點…啊不對，改成週三十點" spans
    ///   a sentence boundary by definition.
    /// - **The system prompt is prefilled once**, not per sentence: ~650 tokens
    ///   against ~3,900 for a six-sentence dictation.
    ///
    /// **Sampling stays at 0.1, not greedy.** `QwenModelHost` documents that this
    /// 4-bit model falls into token-repetition loops at very low temperature, and
    /// a passage generates ten times the tokens of a sentence — so the risk is
    /// higher here, not lower.
    ///
    /// The repetition window is widened instead: 20 tokens is right for a
    /// one-sentence answer and blind to any loop with a longer period.
    func repairPassage(
        _ passage: String,
        origin: PromptInputOrigin,
        mergesSelfCorrections: Bool,
        onProgress: (@Sendable (Int) -> Void)? = nil,
        prepareModel: (@MainActor () async -> String?)? = nil
    ) async -> PassageOutcome {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unchanged }
        if let prepareModel, await prepareModel() != nil { return .modelSilent }

        let system = TranscriptRepairPrompt.system(
            origin: origin, mergesSelfCorrections: mergesSelfCorrections
        )
        let cap = TranscriptRepairPrompt.tokenCap(for: trimmed)

        // Watch the token count for two things the output alone cannot tell us.
        //
        // Truncation is the first. A generation that stops because it hit the cap
        // has lost its tail, and on a passage that is not one missing sentence
        // but the last third of everything — which can still pass a length floor
        // if the cap was generous. The counter says so exactly, where the gate
        // could only guess.
        // Always the streaming call, even with no progress handler.
        //
        // The counter is what detects truncation, and it was only fed on the
        // streaming branch — so `repairPassage(..., onProgress: nil, ...)` could
        // never report `.truncated` and would hand a passage cut a third short to
        // the gate as if it were complete. The gate cannot tell from the text;
        // that is why the counter exists. The two branches also had no other
        // difference worth keeping.
        let produced = TokenCounter()
        let raw = await host.generateStreaming(
            system: system, user: TranscriptRepairPrompt.user(trimmed), maxTokens: cap,
            temperature: 0.1, topP: 0.9, repetitionPenalty: 1.05,
            repetitionContextSize: Self.passageRepetitionWindow,
            shouldStop: { Task.isCancelled },
            onProgress: { count in
                produced.record(count)
                onProgress?(count)
            }
        )
        guard let raw else { return .modelSilent }
        guard !Task.isCancelled else { return .modelSilent }
        if produced.value >= cap - QwenModelHost.progressStride { return .rejected(.truncated) }

        let candidate = PassageRepairGate.sanitize(raw)
        if let reason = PassageRepairGate.rejection(original: trimmed, corrected: candidate) {
            return reason == .unchanged ? .unchanged : .rejected(reason)
        }
        return .repaired(candidate)
    }

    /// Repair one sentence.
    ///
    /// The fallback path, kept because it is the proven one: when a passage
    /// repair is rejected, this still produces a result, one gated sentence at a
    /// time. Also the only path for text short enough that `PromptRepairGate`
    /// judges a whole passage not worth a generation.
    ///
    /// `context` carries the neighbouring sentences so a name spelled once stays
    /// spelled that way throughout.
    func repair(
        _ text: String,
        origin: PromptInputOrigin,
        context: [String] = [],
        prepareModel: (@MainActor () async -> String?)? = nil
    ) async -> Outcome {
        guard PromptRepairGate.shouldAttempt(text) else { return .skipped }
        // Load through the owner, like every other generation. Calling
        // `host.generate` straight through started a silent 2.3 GB download with
        // the UI showing "整理逐字稿 0/7", outside the failure budget and racing
        // the meeting's prefetch into the same directory.
        if let prepareModel, await prepareModel() != nil { return .modelSilent }

        let first = await attempt(text, origin: origin, context: context, reinforceTraditional: false)
        // One retry, and only for the script failure.
        //
        // Qwen3-4B-Instruct is trained predominantly on Simplified Chinese and
        // drifts into it even when told not to — "keep the same language" is
        // satisfied by Simplified, and a single rule in a system prompt does not
        // outweigh the training distribution. Rejecting alone was correct but
        // wasted the generation and left the typo unfixed, so the second attempt
        // shows the model what Traditional output looks like instead of only
        // telling it. Not retried for any other rejection: those mean the model
        // did something wrong that a reworded prompt will not fix, and a retry
        // would just double the latency.
        guard case let .rejected(reason) = first, reason == .simplifiedChinese else {
            return first
        }
        return await attempt(text, origin: origin, context: context, reinforceTraditional: true)
    }

    private func attempt(
        _ text: String,
        origin: PromptInputOrigin,
        context: [String],
        reinforceTraditional: Bool
    ) async -> Outcome {
        guard let output = await host.generate(
            system: Self.systemPrompt(for: origin, reinforceTraditional: reinforceTraditional),
            user: Self.userPrompt(text, context: context),
            maxTokens: Self.tokenCap(for: text),
            temperature: 0.1, topP: 0.9, repetitionPenalty: 1.05
        ) else { return .modelSilent }

        let candidate = PromptRepairGate.sanitize(output)
        if let reason = PromptRepairGate.rejection(original: text, corrected: candidate) {
            return reason == .unchanged ? .unchanged : .rejected(reason)
        }
        return .repaired(candidate)
    }

    /// A repair is the same sentence said correctly, so the cap sits above the
    /// input's own length with room for the model to open with a stray space or
    /// quote before the answer.
    ///
    /// Measured in estimated tokens rather than "units": a 40-character Chinese
    /// line is ~36 tokens but only 13 units, and `units * 3` gave it 48 — enough
    /// to echo the line back and nothing more, so any preamble at all pushed the
    /// answer past the cap and the truncated result was thrown away by the gate.
    static func tokenCap(for text: String) -> Int {
        min(512, max(64, Int(Double(TokenEstimator.estimate(text)) * 2.0)))
    }

    // MARK: - Prompts

    /// One shared contract, one origin-specific error model.
    ///
    /// The shared half is negative-heavy on purpose: the failure mode of a 4B
    /// model on a "fix this" instruction is doing something more interesting
    /// than fixing it.
    static func systemPrompt(
        for origin: PromptInputOrigin, reinforceTraditional: Bool = false
    ) -> String {
        let traditionalExample = reinforceTraditional ? """

        The previous attempt returned Simplified characters and was discarded. \
        Traditional is REQUIRED. Study the difference:
        WRONG (Simplified): 请帮我检查这个设计并优化编译错误
        RIGHT (Traditional): 請幫我檢查這個設計並優化編譯錯誤
        Every character you output must be the Traditional form.
        """ : ""

        return """
        You repair one line of a software request so it reads correctly. \
        \(errorModel(for: origin))
        Rules:
        - Output ONLY the repaired line. No quotes, labels, notes or explanations.
        - Write it in the SAME language as the input. Never translate.
        - If the input is Chinese, write Traditional Chinese as used in Taiwan \
        (台灣正體中文). NEVER output Simplified characters — 简体字 is wrong output \
        here even though it is the same language.
        - NEVER rephrase, summarize, shorten, expand or answer the request.
        - Keep identifiers, file names, paths, commands and flags exactly as \
        given, except to restore punctuation a dictation lost \
        (\"sources uploader dot swift\" → \"Sources/Uploader.swift\").
        - NEVER change any number, version or unit.
        - NEVER add or remove a negation. If the line forbids something, the \
        repaired line must still forbid it.
        - If nothing is clearly wrong, return the line exactly as given.
        - \"Context:\" is the surrounding text, for reference only — never repeat it.

        \(examples(for: origin))\(traditionalExample)
        """
    }

    /// Worked examples of the error class, because naming it is not enough.
    ///
    /// Without these the model returned the line almost untouched: given
    /// "書出提示詞的選項" it deleted one comma and left 書出 — a wrong homophone
    /// of 輸出 — in place. The instructions were a wall of "NEVER …", which is
    /// the framing Anthropic's own guidance says works least well, so the safest
    /// thing the model could do was nothing.
    ///
    /// The examples show the fix that matters most for Chinese input: 同音錯別字,
    /// characters that sound right and are wrong. They also show what to leave
    /// alone, so "be bolder" does not turn into rewriting.
    static func examples(for origin: PromptInputOrigin) -> String {
        let shared = """
        Examples — fix wrong characters, keep everything else:
        In:  書出提示詞的選項，不用其他JSON，最後進行程式碼測試都沒問題才行
        Out: 輸出提示詞的選項，不用其他JSON，最後進行程式碼測試都沒問題才行
        (書出 → 輸出: a homophone. The commas and JSON are correct — left alone.)

        In:  幫我在 Sources/Uploader.swift 加上從試機制，測試藥過
        Out: 幫我在 Sources/Uploader.swift 加上重試機制，測試要過
        (從試 → 重試, 藥過 → 要過. The path is untouched.)

        In:  Add a retry to teh uploader, it fials on 5xx erors
        Out: Add a retry to the uploader; it fails on 5xx errors.
        (Spelling and punctuation only.)

        In:  refactor uploadChunk 但不要動 public API
        Out: refactor uploadChunk 但不要動 public API
        (Nothing is wrong. Returned unchanged.)
        """
        guard origin == .speech else { return shared }
        return shared + """


        Dictated input also mis-hears whole terms:
        In:  use cooper netties for the deploy
        Out: use Kubernetes for the deploy
        """
    }

    /// What kind of mistake to expect. Naming the error class is most of the
    /// instruction: a model told to look for mis-hearings in typed text will
    /// find them whether or not they exist.
    static func errorModel(for origin: PromptInputOrigin) -> String {
        switch origin {
        case .speech:
            return """
                The line came from a speech recognizer, so expect mis-heard words, \
                wrong homophones, mangled technical terms and missing punctuation.
                """
        case .typed:
            return """
                The line was typed, so expect typos, wrong characters, missing \
                punctuation and inconsistent capitalization — NOT mis-hearings. \
                The words are the ones the writer meant; only the spelling may be wrong.
                """
        case .mixed:
            return """
                Part of the line was dictated and part was typed, so expect both \
                mis-heard words and typos.
                """
        }
    }

    static func userPrompt(_ text: String, context: [String]) -> String {
        let recent = context.suffix(2).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !recent.isEmpty else { return "Line: \(text)" }
        let block = recent.map { "- \($0)" }.joined(separator: "\n")
        return "Context:\n\(block)\n\nLine: \(text)"
    }
}
