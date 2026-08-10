import Foundation
import Testing
@testable import FlowTranslateCore

/// Keeping the second caption on screen across a finalize.
///
/// The bug: a finalized utterance that split into several sentences threw away
/// the live translation, so the Chinese line blanked to `⋯` and came back a
/// second or two later — for text the app had already translated. Reading a
/// caption that disappears and returns is the jump this exists to remove.
@Suite struct InterimTranslationPairingTests {

    @Test func oneSentenceKeepsTheWholeTranslation() {
        let paired = InterimTranslationPairing.pair(interim: "這是一句話。", toSentenceCount: 1)
        #expect(paired == ["這是一句話。"])
    }

    @Test func twoSentencesAreSplitToMatch() {
        let paired = InterimTranslationPairing.pair(
            interim: "第一句話。第二句話。", toSentenceCount: 2
        )
        #expect(paired?.count == 2)
        #expect(paired?[0].contains("第一") == true)
        #expect(paired?[1].contains("第二") == true)
    }

    /// No honest pairing means no pairing: sentence two's translation under
    /// sentence one is worse than a pending marker, because it does not announce
    /// itself as provisional.
    @Test func mismatchedCountsYieldNothing() {
        #expect(InterimTranslationPairing.pair(interim: "只有一句。", toSentenceCount: 3) == nil)
        #expect(InterimTranslationPairing.pair(interim: "一句。兩句。三句。", toSentenceCount: 2) == nil)
    }

    @Test func emptyInterimYieldsNothing() {
        #expect(InterimTranslationPairing.pair(interim: "   ", toSentenceCount: 1) == nil)
        #expect(InterimTranslationPairing.pair(interim: "有字。", toSentenceCount: 0) == nil)
    }

    @Test func englishSplitsToo() {
        let paired = InterimTranslationPairing.pair(
            interim: "First sentence. Second sentence.", toSentenceCount: 2
        )
        #expect(paired?.count == 2)
    }

    // MARK: - What the band does with it

    @Test("a multi-sentence commit no longer blanks the translation")
    func theBandKeepsTheProvisionalText() {
        var band = CaptionBandState(historyLimit: 3)
        let utterance = UUID()
        band.interim(utteranceId: utterance, source: .microphone,
                     english: "First sentence. Second sentence.",
                     chinese: "第一句話。第二句話。", expectsTranslation: true)

        let first = UUID(), second = utterance
        band.commit(
            utteranceId: utterance, source: .microphone,
            sentences: [(key: first, english: "First sentence."),
                        (key: second, english: "Second sentence.")],
            expectsTranslation: true,
            provisional: [first: "第一句話。", second: "第二句話。"]
        )
        #expect(band.visibleCommitted.first?.chinese == "第一句話。")
        #expect(band.visibleSlot?.chinese == "第二句話。")
    }

    @Test("with no honest pairing the pending marker still applies")
    func unpairedStillClears() {
        var band = CaptionBandState(historyLimit: 3)
        let utterance = UUID()
        band.interim(utteranceId: utterance, source: .microphone,
                     english: "One. Two.", chinese: "只有一句。", expectsTranslation: true)
        band.commit(
            utteranceId: utterance, source: .microphone,
            sentences: [(key: UUID(), english: "One."), (key: utterance, english: "Two.")],
            expectsTranslation: true,
            provisional: [:]
        )
        #expect(band.visibleSlot?.chinese == nil)
    }

    /// The accurate translation must still win when it lands.
    @Test("an accurate translation replaces the provisional one")
    func accurateReplacesProvisional() {
        var band = CaptionBandState(historyLimit: 3)
        let utterance = UUID()
        band.interim(utteranceId: utterance, source: .microphone,
                     english: "Hello.", chinese: "哈囉。", expectsTranslation: true)
        band.commit(utteranceId: utterance, source: .microphone,
                    sentences: [(key: utterance, english: "Hello.")],
                    expectsTranslation: true, provisional: [utterance: "哈囉。"])
        band.translation(key: utterance, text: "你好。")
        #expect(band.visibleSlot?.chinese == "你好。")
    }
}
