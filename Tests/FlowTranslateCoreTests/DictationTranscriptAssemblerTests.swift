import Testing
@testable import FlowTranslateCore

@Suite("Dictation transcript assembly")
struct DictationTranscriptAssemblerTests {

    // MARK: - Joining

    @Test("Apple's segments concatenate — their leading space is the join")
    func appleSegmentsConcatenate() {
        let joined = DictationTranscriptAssembler.join(
            "Hello", " there", segmentsCarryOwnSpacing: true)
        #expect(joined == "Hello there")
    }

    @Test("No space is invented inside a Chinese sentence")
    func chineseSegmentsGetNoSeparator() {
        let joined = DictationTranscriptAssembler.join(
            "為何我開", "內建的", segmentsCarryOwnSpacing: true)
        #expect(joined == "為何我開內建的")
    }

    @Test("Nemotron's bare words get the separator they need")
    func bareWordsGetSeparator() {
        let joined = DictationTranscriptAssembler.join(
            "Hello", "there", segmentsCarryOwnSpacing: false)
        #expect(joined == "Hello there")
    }

    // MARK: - The duplication bug

    /// The regression this type exists for. The drain finalized the utterance and
    /// revised it while doing so, so a substring test could not see that the
    /// interim was already represented — and the user's last sentence was inserted
    /// twice.
    @Test("A revised final does not cause the interim to be appended again")
    func revisedFinalIsNotDuplicated() {
        let assembled = DictationTranscriptAssembler.assemble(
            transcript: "為何我開內建的 Mac，Mac 跟你做的辨識結果會不一樣",
            carriedInterim: "為何我開內建的",       // volatile, pre-revision
            drainProducedText: true,
            segmentsCarryOwnSpacing: true)
        #expect(assembled == "為何我開內建的 Mac，Mac 跟你做的辨識結果會不一樣")
    }

    @Test("Punctuation added during finalization does not cause duplication")
    func punctuationRevisionIsNotDuplicated() {
        let assembled = DictationTranscriptAssembler.assemble(
            transcript: "Let's ship the release build.",
            carriedInterim: "lets ship the release build",
            drainProducedText: true,
            segmentsCarryOwnSpacing: true)
        #expect(assembled == "Let's ship the release build.")
    }

    // MARK: - Keeping the interim when it is all there is

    /// The opposite failure, equally severe: a dictation is frequently one
    /// sentence that never finalizes, and discarding the interim loses all of it.
    @Test("An interim that never finalized is kept")
    func unfinalizedInterimIsKept() {
        let assembled = DictationTranscriptAssembler.assemble(
            transcript: "",
            carriedInterim: "幫我把這段話整理成一封信",
            drainProducedText: false,
            segmentsCarryOwnSpacing: true)
        #expect(assembled == "幫我把這段話整理成一封信")
    }

    @Test("An un-drained interim is appended to earlier finalized text")
    func unfinalizedInterimIsAppended() {
        let assembled = DictationTranscriptAssembler.assemble(
            transcript: "第一句已經完成。",
            carriedInterim: "第二句還在辨識中",
            drainProducedText: false,
            segmentsCarryOwnSpacing: true)
        #expect(assembled == "第一句已經完成。第二句還在辨識中")
    }

    // MARK: - The pre-drain containment case

    @Test("An interim already finalized before the key press is not repeated")
    func alreadyFinalizedInterimIsNotRepeated() {
        let assembled = DictationTranscriptAssembler.assemble(
            transcript: "幫我把這段話整理成一封信",
            carriedInterim: "整理成一封信",
            drainProducedText: false,
            segmentsCarryOwnSpacing: true)
        #expect(assembled == "幫我把這段話整理成一封信")
    }

    /// Spacing differs between a final and its interim by design, so it must not
    /// be what decides the comparison.
    @Test("Containment ignores whitespace differences")
    func containmentIgnoresWhitespace() {
        let assembled = DictationTranscriptAssembler.assemble(
            transcript: "為何我開內建的 Mac",
            carriedInterim: "為何我開內建的Mac",
            drainProducedText: false,
            segmentsCarryOwnSpacing: true)
        #expect(assembled == "為何我開內建的 Mac")
    }

    // MARK: - Edges

    @Test("An empty interim changes nothing")
    func emptyInterimIsInert() {
        let assembled = DictationTranscriptAssembler.assemble(
            transcript: "完整的句子", carriedInterim: "   ",
            drainProducedText: false, segmentsCarryOwnSpacing: true)
        #expect(assembled == "完整的句子")
    }

    @Test("Nothing recognized yields nothing")
    func emptyEverythingIsEmpty() {
        let assembled = DictationTranscriptAssembler.assemble(
            transcript: "", carriedInterim: "",
            drainProducedText: false, segmentsCarryOwnSpacing: true)
        #expect(assembled.isEmpty)
    }
}
