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
