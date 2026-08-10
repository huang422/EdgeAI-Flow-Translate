import Testing
@testable import FlowTranslateCore

@Suite struct TranscriptCorrectionGateTests {

    // MARK: - Intake filter

    @Test func skipsUtterancesTooShortToRepair() {
        // The acknowledgements that dominate a meeting: nothing to fix, and the
        // highest relative risk of an LLM inventing something.
        #expect(TranscriptCorrectionGate.shouldAttempt("Okay.") == false)
        #expect(TranscriptCorrectionGate.shouldAttempt("Yes, sure.") == false)
        #expect(TranscriptCorrectionGate.shouldAttempt("   ") == false)
        #expect(TranscriptCorrectionGate.shouldAttempt("") == false)
    }

    @Test func acceptsSentencesWorthCorrecting() {
        #expect(TranscriptCorrectionGate.shouldAttempt("we should deploy this on Friday") == true)
    }

    @Test func cjkFloorCountsCharactersNotWords() {
        // CJK tokenizes per character, so the word-level floor of 4 would let a
        // two-word greeting through. Short Chinese is skipped, real sentences pass.
        #expect(TranscriptCorrectionGate.shouldAttempt("你好嗎？") == false)
        #expect(TranscriptCorrectionGate.shouldAttempt("我們明天早上再討論這個問題") == true)
    }

    // MARK: - Output gate

    @Test func rejectsNonRepairs() {
        let original = "we should deploy this on Friday"
        // Unchanged, empty, and multi-line answers are all non-answers.
        #expect(TranscriptCorrectionGate.accepts(original: original, corrected: original) == false)
        #expect(TranscriptCorrectionGate.accepts(original: original, corrected: "  ") == false)
        #expect(TranscriptCorrectionGate.accepts(original: original, corrected: "we should\ndeploy") == false)
        #expect(TranscriptCorrectionGate.accepts(original: "", corrected: "anything") == false)
    }

    @Test func rejectsWholesaleRewrites() {
        // A paraphrase, not a repair — the edit-distance bound is what stops the
        // corrector from quietly rewriting the speaker.
        #expect(TranscriptCorrectionGate.accepts(
            original: "we should deploy this on Friday",
            corrected: "the team plans a release before the weekend") == false)
    }

    @Test func rejectsLengthExplosionAndCollapse() {
        let original = "we should deploy this on Friday afternoon"
        #expect(TranscriptCorrectionGate.accepts(original: original, corrected: "deploy") == false)
        #expect(TranscriptCorrectionGate.accepts(
            original: original,
            corrected: original + " " + original + " and also everything else here") == false)
    }

    @Test func acceptsAPlausibleRepair() {
        // The homophone/proper-noun case GER exists for. Measured in characters:
        // word-level counting would score this 3 edits out of 6 words and reject
        // the very repair the gate exists to let through.
        #expect(TranscriptCorrectionGate.accepts(
            original: "lets deploy to cooper netties tomorrow",
            corrected: "let's deploy to Kubernetes tomorrow") == true)
    }

    @Test func acceptsPunctuationOnlyRepair() {
        #expect(TranscriptCorrectionGate.accepts(
            original: "so what do you think about the migration",
            corrected: "So, what do you think about the migration?") == true)
    }

    // MARK: - Numbers

    @Test func numbersMustSurviveUntouched() {
        // Silently changing a figure is the one error nobody would catch by eye.
        #expect(TranscriptCorrectionGate.accepts(
            original: "the budget is 300 thousand for v2",
            corrected: "the budget is 800 thousand for v2") == false)
        #expect(TranscriptCorrectionGate.accepts(
            original: "the budget is 300 thousand for v2",
            corrected: "the budget is 300 thousand for v3") == false)
    }

    @Test func digitRunsAreOrderInsensitiveMultiset() {
        #expect(TranscriptCorrectionGate.digitRuns("v2 costs 300") == ["2", "300"])
        #expect(TranscriptCorrectionGate.digitRuns("300 for v2") == ["2", "300"])
        #expect(TranscriptCorrectionGate.digitRuns("no numbers here") == [])
    }

    @Test func repairsACJKHomophone() {
        // CJK tokenizes per character, so a one-character fix in a short sentence
        // must still land inside the distance bound.
        #expect(TranscriptCorrectionGate.accepts(
            original: "我們明天早上再討論這個問題",
            corrected: "我們明天早上再討論這個問題。") == true)
    }

    // MARK: - Sanitizing the model's answer

    @Test func stripsLabelsQuotesAndTrailingNotes() {
        let line = "We run it on Kubernetes."
        #expect(TranscriptCorrectionGate.sanitize("Corrected: \(line)") == line)
        #expect(TranscriptCorrectionGate.sanitize("\"\(line)\"") == line)
        #expect(TranscriptCorrectionGate.sanitize("「\(line)」") == line)
        #expect(TranscriptCorrectionGate.sanitize("\(line)\n(no changes needed)") == line)
        #expect(TranscriptCorrectionGate.sanitize("  \(line)  ") == line)
    }

    @Test func sanitizeLeavesACleanAnswerAlone() {
        // Apostrophes and inch marks inside a line must survive — only a matching
        // pair wrapping the WHOLE line is decoration.
        #expect(TranscriptCorrectionGate.sanitize("It's a 24\" monitor") == "It's a 24\" monitor")
    }

    // MARK: - Decode caps

    @Test func unitEstimateHandlesUnspacedScripts() {
        // A whole Chinese line is ONE whitespace "word" — without the character
        // proxy the decode cap would pin to its floor and truncate long lines.
        #expect(SpokenTextMetrics.units("我們明天早上再討論這個問題") == 4)   // proxy, not 1
        // The two estimates deliberately take the max, so a decode cap always
        // over- rather than under-provisions; for spaced text the proxy usually
        // wins (English averages well under three characters per token).
        #expect(SpokenTextMetrics.units("we should deploy this on Friday") == 10)
        #expect(SpokenTextMetrics.units("") == 1)
    }

}

/// Chinese numerals are words, not numbers.
///
/// `Character.isNumber` is true for 一/十/百, so every ordinary Chinese sentence
/// looked like it contained digits and almost every Chinese repair was rejected
/// as "the numbers changed". Seen in the field as
/// `fallback=numberInvented rejected=numberChanged [identical]` on a 13-character
/// passage containing no digit at all.
@Suite struct ChineseNumeralTests {

    @Test(arguments: ["幫我看一下", "第一個檔案", "十分重要", "兩三個問題"])
    func ordinaryChineseHasNoDigitRuns(_ text: String) {
        #expect(TranscriptCorrectionGate.digitRuns(text).isEmpty, "\(text)")
    }

    @Test func arabicDigitsAreStillProtected() {
        #expect(TranscriptCorrectionGate.digitRuns("timeout 設成 30 秒，重試 3 次")
            == ["3", "30"])
    }

    /// The repair this used to reject.
    @Test func aChineseRepairIsNoLongerRejectedAsANumberChange() {
        let spoken = "幫我看一下這段城市碼"
        let fixed = "幫我看一下這段程式碼。"
        #expect(PassageRepairGate.rejection(original: spoken, corrected: fixed) == nil,
                "\(String(describing: PassageRepairGate.rejection(original: spoken, corrected: fixed)))")
    }

    /// And an actual invented number is still caught.
    @Test func aRealInventedNumberIsStillRejected() {
        #expect(PassageRepairGate.rejection(
            original: "把逾時設定調高一點",
            corrected: "把逾時設定調高到 30 秒"
        ) != nil)
    }

    /// Full-width numerals are numbers, and Qwen emits them in Chinese text
    /// routinely. Skipping them left the "numbers are sacred" rule with nothing
    /// to compare, so a changed price passed the gate into the transcript.
    @Test func fullWidthDigitsAreProtected() {
        #expect(TranscriptCorrectionGate.digitRuns("價格３００元") == ["300"])
        #expect(TranscriptCorrectionGate.digitRuns("價格３００元")
            != TranscriptCorrectionGate.digitRuns("價格５００元"))
        #expect(PassageRepairGate.rejection(original: "價格３００元", corrected: "價格５００元") != nil)
    }

    /// Width alone is not a changed number, so folding is also what makes the
    /// harmless normalization pass.
    @Test func fullWidthAndAsciiFormsOfOneNumberMatch() {
        #expect(TranscriptCorrectionGate.digitRuns("價格３００元")
            == TranscriptCorrectionGate.digitRuns("價格 300 元"))
    }
}

/// The meeting corrector and the two dictation repairers share one model, and
/// that model drifts into Simplified whenever an instruction says only "keep the
/// same language". Both dictation gates have checked for it from the start; this
/// one did not, so a Chinese meeting with correction on could have its recorded
/// transcript — and therefore its summary and every export — converted sentence
/// by sentence, well inside the edit-distance budget.
@Suite("Correction never changes the script")
struct CorrectionScriptGuardTests {

    /// The realistic shape, and the one nothing else in the gate catches: an
    /// ordinary technical sentence has only a handful of Simplified-only forms in
    /// it, so a conversion moves far too few characters to trip the 0.35 distance
    /// budget. A wholesale rewrite would have been rejected anyway; this is the
    /// case the rule exists for.
    private static let traditional = "把重試機制加到上傳器，timeout 設成三十秒"
    private static let converted   = "把重试机制加到上传器，timeout 设成三十秒"

    @Test("a Simplified rewrite is rejected")
    func rejectsSimplifiedConversion() {
        #expect(!TranscriptCorrectionGate.accepts(
            original: Self.traditional, corrected: Self.converted
        ))
    }

    /// …and it passes every *other* rule, which is why the gate needed a new one
    /// rather than a tighter threshold.
    @Test("a conversion passes the other rules, so this one has to catch it")
    func conversionPassesEveryOtherRule() {
        let original = Self.traditional, converted = Self.converted
        #expect(original != converted)
        #expect(!converted.contains("\n"))
        let ratio = Double(converted.count) / Double(original.count)
        #expect((0.5...2.0).contains(ratio))
        #expect(TranscriptCorrectionGate.digitRuns(original)
                == TranscriptCorrectionGate.digitRuns(converted))
        let a = Array(original.lowercased()), b = Array(converted.lowercased())
        let drift = Double(TranscriptCorrectionGate.levenshtein(a, b)) / Double(max(a.count, b.count))
        #expect(drift <= 0.35)
    }

    /// A genuine repair of Traditional text still gets through.
    @Test("a real Traditional repair is still accepted")
    func acceptsTraditionalRepair() {
        #expect(TranscriptCorrectionGate.accepts(
            original: "幫我在上傳器加上從試機制，測試藥過",
            corrected: "幫我在上傳器加上重試機制，測試要過"
        ))
    }

    /// Someone whose source text is already Simplified is not blocked from having
    /// it repaired — only *introducing* the script is caught.
    @Test("text that was already Simplified can still be repaired")
    func alreadySimplifiedIsNotBlocked() {
        #expect(TranscriptCorrectionGate.accepts(
            original: "这个设计要说明清楚，测试也要通过啊",
            corrected: "这个设计要说明清楚，测试也要通过"
        ))
    }
}
