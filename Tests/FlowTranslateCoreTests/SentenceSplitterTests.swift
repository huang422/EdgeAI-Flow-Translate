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
