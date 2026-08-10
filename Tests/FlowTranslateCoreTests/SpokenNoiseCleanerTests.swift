import Testing
@testable import FlowTranslateCore

@Suite struct SpokenNoiseCleanerTests {

    private let cleaner = SpokenNoiseCleaner()

    // MARK: - What must survive
    //
    // These are the tests that matter most. Chinese discourse markers and
    // reduplication look like noise and are not: deleting them changes what the
    // user asked for, which is the one failure this component must never have.

    @Test func keepsChineseDiscourseMarkersThatCarryMeaning() {
        #expect(cleaner.cleanup("然後呢？") == "然後呢？")
        #expect(cleaner.cleanup("就是這個檔案") == "就是這個檔案")
        #expect(cleaner.cleanup("那個檔案要改") == "那個檔案要改")
        #expect(cleaner.cleanup("反正先做這個") == "反正先做這個")
    }

    @Test func keepsChineseReduplication() {
        // 看看 / 常常 / 研究研究 are ordinary morphology, not stutter. A
        // repeated-token rule cannot distinguish them, so it is never applied
        // to CJK at all.
        #expect(cleaner.cleanup("看看這個測試") == "看看這個測試")
        #expect(cleaner.cleanup("我們研究研究這個問題") == "我們研究研究這個問題")
        #expect(cleaner.cleanup("常常會失敗") == "常常會失敗")
    }

    @Test func keepsEnglishDiscoursePhrases() {
        // Same rule as BasicTextCleaner: multi-word phrases carry meaning far
        // more often than they look like they do.
        #expect(cleaner.cleanup("what kind of car is it") == "what kind of car is it")
        #expect(cleaner.cleanup("do you know the answer") == "do you know the answer")
    }

    // MARK: - What gets removed

    @Test func removesEnglishHesitationSounds() {
        #expect(cleaner.cleanup("um add a retry") == "add a retry")
        #expect(cleaner.cleanup("add uh a retry") == "add a retry")
        #expect(cleaner.cleanup("um um add a retry") == "add a retry")
    }

    @Test func removesChineseInterjections() {
        #expect(cleaner.cleanup("嗯 我想加一個 retry") == "我想加一個 retry")
        #expect(cleaner.cleanup("呃這個檔案要改") == "這個檔案要改")
        // Removing the interjection preserves the request itself.
        #expect(cleaner.cleanup("欸你看這個") == "你看這個")
    }

    @Test func collapsesEnglishStutters() {
        #expect(cleaner.cleanup("fix the the upload bug") == "fix the the upload bug".replacingOccurrences(of: "the the", with: "the"))
        #expect(cleaner.cleanup("I I need a retry") == "I need a retry")
    }

    @Test func neverReturnsEmptyForAnAllInterjectionUtterance() {
        // Nothing to compile either way, but an empty string would look like a
        // crash to the caller.
        #expect(cleaner.cleanup("嗯") == "嗯")
        #expect(cleaner.cleanup("嗯 呃") == "嗯 呃")
    }

    @Test func tidiesSpaceStrandedBeforePunctuation() {
        #expect(cleaner.cleanup("add a retry um , then test") == "add a retry, then test")
        #expect(cleaner.cleanup("加一個 retry 嗯 。") == "加一個 retry。")
    }

    // MARK: - Origin gating

    @Test func typedInputIsNeverCleaned() {
        // A deliberate "嗯" in typed text, or a fragment inside a pasted code
        // snippet, must survive untouched.
        let typed = "嗯 um the the"
        #expect(cleaner.cleanup(typed, origin: .typed) == typed)
        #expect(cleaner.cleanup(typed, origin: .speech) != typed)
        #expect(cleaner.cleanup(typed, origin: .mixed) != typed)
    }

    @Test func originExposesWhetherCleanupApplies() {
        #expect(PromptInputOrigin.typed.needsSpokenCleanup == false)
        #expect(PromptInputOrigin.speech.needsSpokenCleanup == true)
        #expect(PromptInputOrigin.mixed.needsSpokenCleanup == true)
    }
}

/// Tidy fixes characters. It is not allowed to re-flow the request.
///
/// A typed request is written one requirement per line, and the whole pass used
/// to collapse it: sentence splitting does not treat a newline as a boundary, and
/// the rejoin used a single space, so five lines came back as one paragraph.
@Suite("Request line structure")
struct RequestOutlineTests {

    @Test("a five-line request stays five lines")
    func lineCountSurvives() {
        let request = """
        改成 XML 標籤輸出
        讓使用者選 claude 或 codex
        不要新增套件
        測試要過
        最後詳細檢查
        """
        let outline = RequestOutline(request)
        #expect(outline.sentences.count == 5)
        let rebuilt = outline.rejoined(with: outline.sentences)
        #expect(rebuilt.components(separatedBy: "\n").count == 5)
        #expect(rebuilt == request)
    }

    @Test("a line holding two sentences keeps both on that line")
    func sentencesRejoinWithinTheirLine() {
        let outline = RequestOutline("First thing. Second thing.\nThird thing.")
        #expect(outline.sentences == ["First thing.", "Second thing.", "Third thing."])
        #expect(outline.rejoined(with: outline.sentences)
            == "First thing. Second thing.\nThird thing.")
    }

    @Test("a blank line between paragraphs is content")
    func blankLinesSurvive() {
        let outline = RequestOutline("Alpha\n\nBeta")
        #expect(outline.rejoined(with: outline.sentences) == "Alpha\n\nBeta")
    }

    @Test("repairs land on the line they came from")
    func repairsKeepTheirPlace() {
        let outline = RequestOutline("teh first\nteh second")
        #expect(outline.rejoined(with: ["the first", "the second"]) == "the first\nthe second")
    }

    /// A cancelled pass hands back fewer repairs than there were sentences. The
    /// remainder must fall back to the original, never vanish.
    @Test("a short repair list does not delete the tail")
    func partialRepairsKeepTheRest() {
        let outline = RequestOutline("alpha\nbeta\ngamma")
        #expect(outline.rejoined(with: ["ALPHA"]) == "ALPHA\nbeta\ngamma")
    }

    @Test("the spoken cleaner no longer eats newlines")
    func cleanerKeepsNewlines() {
        let cleaned = SpokenNoiseCleaner().cleanup("um add a retry\nuh and a test")
        #expect(cleaned == "add a retry\nand a test")
    }
    /// The case that was losing content: `SentenceSplitter.split` drops any line
    /// with no letter or digit — correct for a caption, where a punctuation-only
    /// utterance is noise, and destructive here, where the tidy pass writes this
    /// result straight back over the user's request.
    @Test("a delimiter line survives the round trip")
    func delimiterLinesSurvive() {
        let request = """
        Fix the uploader:

        ```
        retry(attempts: 3)
        ```

        ---
        Tests must pass.
        """
        let outline = RequestOutline(request)
        // Unrepaired: every sentence maps to itself.
        #expect(outline.rejoined(with: outline.sentences) == request)
    }

    /// A delimiter is offered to the repairer as its own unit, and the gate
    /// declines it — so it can never be rewritten into something else.
    @Test("a delimiter is never worth a repair generation")
    func delimitersAreNotRepaired() {
        let outline = RequestOutline("```\ncode\n```")
        #expect(outline.sentences.contains("```"))
        for sentence in outline.sentences where !sentence.contains(where: \.isLetter) {
            #expect(!PromptRepairGate.shouldAttempt(sentence))
        }
    }
}

