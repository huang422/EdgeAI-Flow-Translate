import Foundation

/// The instruction for repairing a whole dictated passage in one generation.
///
/// In `FlowTranslateCore` rather than beside the model host, so the rules can be
/// asserted on. The per-sentence prompt it grew out of lives in the app target
/// and has never had a test; the protective rules — numbers, identifiers,
/// negations, Traditional Chinese — are the ones most worth pinning down, because
/// losing one is silent.
///
/// **Why one pass rather than one call per sentence.** The per-sentence loop fed
/// each call the two preceding *repaired* sentences as context, which is the
/// exact setup arXiv 2409.09785 measured: previously predicted utterances as
/// context raise word error rate through error propagation, and three utterances
/// is worse than one. A single pass over the raw text has no such feedback, gets
/// cross-sentence consistency for free, and is the only shape in which a
/// self-correction — which spans a sentence boundary by definition — can be seen
/// at all.
public enum TranscriptRepairPrompt {

    /// The passage-repair instruction.
    ///
    /// `mergesSelfCorrections` is what separates this from the per-sentence
    /// prompt, whose first rule is "NEVER rephrase, summarize, shorten". Merging
    /// is a deliberate, bounded exception to that: it deletes text, and
    /// `PassageRepairGate` is what keeps the deletion honest.
    public static func system(
        origin: PromptInputOrigin, mergesSelfCorrections: Bool
    ) -> String {
        var rules = """
        You repair a dictated passage so it reads as the speaker meant it. \
        \(errorModel(for: origin))

        Rules:
        - Output ONLY the repaired passage. No preamble, no labels, no notes, no code fence.
        - Return the SAME LINES, one for one, in the same order. Do not merge or split lines\
        \(mergesSelfCorrections ? " except where a self-correction requires it (see below)" : "").
        - Write it in the SAME language as the input. Never translate.
        - If the input is Chinese, write Traditional Chinese as used in Taiwan (台灣正體中文). \
        NEVER output Simplified characters — 简体字 is wrong output here even though it is the \
        same language.
        - Use the whole passage as context for every word in it. A word that is spelled \
        correctly somewhere is the answer for the same word garbled elsewhere, and a term that \
        makes no sense in the passage's subject is a mis-hearing of one that does.
        - Keep identifiers, file names, paths, commands and flags exactly as given, except to \
        restore punctuation a dictation lost ("sources uploader dot swift" → "Sources/Uploader.swift").
        - NEVER change or invent a number, version, date or unit.
        - NEVER add or remove a negation. If the passage forbids something, it must still forbid it.
        - NEVER answer, explain, summarize or continue the passage. You are fixing it, not replying to it.
        - Fix punctuation and sentence boundaries so it reads as written text rather than a transcript.
        - If the speaker dictated a list, lay it out as a list, one item per line.
        \(origin == .typed ? "" : fillerRule)
        - If nothing is clearly wrong, return the passage exactly as given.
        """

        if mergesSelfCorrections {
            rules += """


            Self-corrections: when the speaker corrects themselves, keep ONLY the corrected \
            version and delete the abandoned one, including the words that marked the \
            correction ("no wait", "actually", "啊不對", "我是說"). This is the ONE case where \
            you may delete what was said, and the ONLY case where two lines may become one. \
            Never delete anything else.
            """
        }

        return rules + "\n\n" + examples(mergesSelfCorrections: mergesSelfCorrections)
    }

    /// The rule that makes this a tidy pass rather than a spellcheck.
    ///
    /// Its absence was a real defect, not a missing nicety. The mode is called
    /// Tidy and is offered for messages, commit bodies and notes, but every rule
    /// above it is protective — the model was told what it must not change and
    /// nothing about what it should improve — so the output came back reading
    /// exactly like the transcript, filler and all, and the feature looked as if
    /// it had not run.
    ///
    /// Bounded in the same sentence that asks for it: padding out, meaning
    /// untouched. `PassageRepairGate` licenses deletion up to the padding it can
    /// actually measure in the passage, so a model that takes this as licence to
    /// rewrite still gets rejected.
    static let fillerRule = """
        - Remove verbal padding: filler and hedges ("um", "you know", "I mean", \
        "sort of", "基本上", "就是說", "然後", "那個"), false starts, and words repeated \
        because the speaker was thinking. Tighten a sentence that says the same thing \
        twice. Keep every fact, name, number and instruction, and keep the speaker's own \
        words for anything that carries meaning — you are removing what they did not \
        intend to say, not rewriting what they did.
        """

    /// What kind of mistake to expect. Naming the error class is most of the
    /// instruction: a model told to look for mis-hearings in typed text will find
    /// them whether or not they exist.
    static func errorModel(for origin: PromptInputOrigin) -> String {
        switch origin {
        case .speech:
            return """
                The passage came from a speech recognizer, so expect mis-heard words, wrong \
                homophones, mangled technical terms, missing punctuation and run-on sentences. \
                A recognizer hears sounds, not meaning: it picks whichever spelling of a sound \
                is commonest, so the wrong word is usually a real word that fits the sound and \
                not the sentence. Read the whole passage first and use what it is ABOUT to \
                choose between spellings that sound the same — the subject, the surrounding \
                sentences, and any technical terms, file names or product names already spelled \
                correctly elsewhere in it are the evidence for what a garbled word must be.
                """
        case .typed:
            return """
                The passage was typed, so expect typos, wrong characters, missing punctuation \
                and inconsistent capitalization — NOT mis-hearings. The words are the ones the \
                writer meant; only the spelling may be wrong.
                """
        case .mixed:
            return """
                Part of the passage was dictated and part was typed, so expect both mis-heard \
                words and typos.
                """
        }
    }

    /// Worked examples, in both scripts.
    ///
    /// The negative example is not optional. Without one the model treats every
    /// passage as needing work and starts rewriting correct sentences, which is
    /// the failure the gate then throws the whole pass away for.
    static func examples(mergesSelfCorrections: Bool) -> String {
        var text = """
        Examples — fix the characters, keep everything else:

        In:
        幫我在 Sources/Uploader.swift 加上從試機制
        測試藥過
        Out:
        幫我在 Sources/Uploader.swift 加上重試機制。
        測試要過。
        (從試 → 重試, 藥過 → 要過. The path is untouched. Two lines in, two lines out.)

        In:
        add a retry to teh uploader it fials on 5xx erors
        Out:
        Add a retry to the uploader; it fails on 5xx errors.
        (Spelling and punctuation only. 5xx is a number — unchanged.)

        In:
        refactor uploadChunk 但不要動 public API
        Out:
        refactor uploadChunk 但不要動 public API
        (Nothing is wrong. Returned exactly as given.)

        In:
        這個副本要用 Redis 做快取 但是 復本 同步會有延遲
        Out:
        這個副本要用 Redis 做快取，但是副本同步會有延遲。
        (復本 → 副本. Both are real words and sound identical; the first line already \
        spelled it 副本, so that is what the second line means.)

        In:
        the parser reeds the manifest then the compiler reads the ir
        Out:
        The parser reads the manifest, then the compiler reads the IR.
        (reeds → reads, decided by the second clause doing the same thing. IR is capitalized \
        because the passage is about a compiler.)

        In:
        那個 我想說 就是 我們是不是可以 就是 把重試機制加到上傳器 然後 timeout 設成 30 秒
        Out:
        我們可以把重試機制加到上傳器，timeout 設成 30 秒。
        (Padding removed. The two facts — 重試機制, 30 秒 — are untouched.)

        In:
        so basically i think we should um kind of add a retry to the uploader you know
        Out:
        We should add a retry to the uploader.
        (Padding removed. Nothing added.)
        """

        guard mergesSelfCorrections else { return text }
        text += """


        In:
        把會議訂在週二下午兩點 啊不對 改成週三早上十點
        Out:
        把會議訂在週三早上十點。
        (A self-correction. The abandoned time and the words marking the correction are gone.)

        In:
        use uploadChunk for this no wait use uploadBlock
        Out:
        Use uploadBlock for this.
        (Same: only the corrected identifier survives.)
        """
        return text
    }

    public static func user(_ passage: String) -> String {
        "Passage:\n\(passage)"
    }

    /// Decode cap for one passage.
    ///
    /// The output is the same length as the input plus the punctuation and
    /// capitalization it restores, so the input's own estimate is the right base.
    /// The ×2 is headroom for a preamble the sanitizer will strip, not for the
    /// passage growing — the gate rejects anything past 1.4× anyway.
    public static func tokenCap(for passage: String) -> Int {
        min(1600, max(128, TokenEstimator.estimate(passage) * 2))
    }
}
