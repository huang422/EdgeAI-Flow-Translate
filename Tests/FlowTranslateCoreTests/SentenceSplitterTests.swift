import Testing
@testable import FlowTranslateCore

@Suite struct SentenceSplitterTests {

    @Test func splitsOnTerminatorsKeepingPunctuation() {
        #expect(SentenceSplitter.split("We shipped it. Does it work? Yes!")
            == ["We shipped it.", "Does it work?", "Yes!"])
    }

    @Test func runOnTerminatorsStayAttachedToTheirWord() {
        // The bug this guards: splitting on EVERY terminator turned "Wait...!"
        // into four segments, three of them nothing but punctuation.
        #expect(SentenceSplitter.split("Wait...!") == ["Wait...!"])
        #expect(SentenceSplitter.split("Really?! Okay.") == ["Really?!", "Okay."])
        #expect(SentenceSplitter.split("Hmm…… fine.") == ["Hmm……", "fine."])
    }

    @Test func neverEmitsAPunctuationOnlyLine() {
        for output in [
            SentenceSplitter.split("Hello. . World."),
            SentenceSplitter.split("Yes. .. No."),
        ] {
            #expect(output.allSatisfy { SentenceSplitter.saysSomething($0) })
        }
    }

    @Test func strayPunctuationBetweenSentencesDoesNotLeadTheNextOne() {
        #expect(SentenceSplitter.split("Hello. . World.") == ["Hello.", "World."])
    }

    @Test func utteranceOfOnlyPunctuationYieldsNothing() {
        // The caller must then DISCARD the utterance; committing an empty list
        // would leave the caption slot stuck mid-sentence forever.
        #expect(SentenceSplitter.split(".").isEmpty)
        #expect(SentenceSplitter.split("… ").isEmpty)
        #expect(SentenceSplitter.split("。。。").isEmpty)
        #expect(SentenceSplitter.split("").isEmpty)
        #expect(SentenceSplitter.split("   ").isEmpty)
    }

    @Test func unterminatedTailIsKept() {
        // The speaker was cut off mid-thought — that is still a caption.
        #expect(SentenceSplitter.split("so we should") == ["so we should"])
        #expect(SentenceSplitter.split("Done. and then we") == ["Done.", "and then we"])
    }

    @Test func handlesFullWidthCJKPunctuation() {
        #expect(SentenceSplitter.split("我們明天討論。可以嗎？")
            == ["我們明天討論。", "可以嗎？"])
    }

    @Test func numbersCountAsContent() {
        // "3." is a real caption (a list item, a version); it must not be
        // mistaken for stray punctuation and dropped.
        #expect(SentenceSplitter.split("3.") == ["3."])
    }

    @Test func decimalsAndVersionsDoNotFragmentIntoEmptyLines() {
        // "v2.1" splits at the dot — unavoidable without a lexicon — but neither
        // half may be punctuation-only.
        let out = SentenceSplitter.split("Ship v2.1 today.")
        #expect(out.allSatisfy { SentenceSplitter.saysSomething($0) })
        #expect(out.joined(separator: " ").contains("2."))
    }
}

/// A caption line of one character flashes past before it can be read, and it
/// still costs a translation request and a transcript row. Real speech produces
/// them constantly — an acknowledgement leading a sentence ("好。我們開始。") is
/// two correct sentences and one wrong caption.
@Suite struct SentenceFragmentTests {

    @Test func aOneCharacterSentenceLeadsTheNextOne() {
        #expect(SentenceSplitter.split("好。我們明天再討論。")
            == ["好。我們明天再討論。"])
        #expect(SentenceSplitter.split("嗯。那我先改這個檔案。")
            == ["嗯。那我先改這個檔案。"])
    }

    @Test func aTrailingFragmentGoesBackOnThePreviousLine() {
        #expect(SentenceSplitter.split("我們明天再討論。好。")
            == ["我們明天再討論。好。"])
    }

    /// Two characters is enough to read. Only the one-character case is merged,
    /// so ordinary short answers keep their own line.
    @Test func shortButReadableSentencesKeepTheirLine() {
        #expect(SentenceSplitter.split("We shipped it. Yes!") == ["We shipped it.", "Yes!"])
        #expect(SentenceSplitter.split("好的。我們開始。") == ["好的。", "我們開始。"])
    }

    /// Dropping something the speaker said would be worse than a short line.
    @Test func aFragmentThatIsTheWholeUtteranceSurvives() {
        #expect(SentenceSplitter.split("好。") == ["好。"])
        #expect(SentenceSplitter.split("3.") == ["3."])
    }

    @Test func englishFragmentsJoinWithASpace() {
        #expect(SentenceSplitter.split("A. Then we ship it.") == ["A. Then we ship it."])
    }

    /// The join is decided by the left side alone: full-width punctuation carries
    /// its own trailing space in the glyph, an ASCII full stop does not.
    @Test func mixedScriptFragmentsJoinCorrectly() {
        #expect(SentenceSplitter.split("好。Then we ship it.") == ["好。Then we ship it."])
        #expect(SentenceSplitter.split("A. 我們明天再討論。") == ["A. 我們明天再討論。"])
    }
}

/// Terminal punctuation in a streaming partial is not proof a sentence ended —
/// the recognizer punctuates what it has so far, so 300 ms into
/// "好，我們開始討論" the partial is "好。" and the early close cut there.
@Suite struct EndpointerSentenceCloseTests {

    @Test func punctuationOnOneCharacterDoesNotCloseEarly() {
        #expect(Endpointer.endsSentence("好。") == false)
        #expect(Endpointer.endsSentence("嗯。") == false)
        #expect(Endpointer.endsSentence("A.") == false)
    }

    @Test func aRealShortSentenceStillClosesEarly() {
        #expect(Endpointer.endsSentence("Yes."))
        #expect(Endpointer.endsSentence("好的。"))
        #expect(Endpointer.endsSentence("We shipped it."))
    }

    @Test func textWithoutTerminalPunctuationNeverCloses() {
        #expect(Endpointer.endsSentence("so we should") == false)
        #expect(Endpointer.endsSentence("") == false)
    }
}
