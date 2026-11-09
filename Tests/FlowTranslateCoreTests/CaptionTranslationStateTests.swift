import Foundation
import Testing
@testable import FlowTranslateCore

/// Generic band-state translation routing remains supported independently of
/// the app's one-ASR-utterance-per-paragraph display policy.
@Suite struct CaptionTranslationStateTests {
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
