import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct EndpointerTests {
    @Test func staysIdleWithoutSpeechStart() {
        var ep = Endpointer()
        for _ in 0..<20 { #expect(ep.process(speechStarted: false, speechEnded: false, sentenceEnded: false, dt: 0.1).isEmpty) }
        #expect(ep.inUtterance == false)
    }

    @Test func startsOnSpeechStart() {
        var ep = Endpointer()
        #expect(ep.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.1) == [.start])
        #expect(ep.inUtterance == true)
    }

    @Test func finalizesOnSpeechEndAfterMinSpeech() {
        var ep = Endpointer(config: .init(minSpeech: 0.30, maxSpeech: 10))
        _ = ep.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.1)
        for _ in 0..<4 { _ = ep.process(speechStarted: false, speechEnded: false, sentenceEnded: false, dt: 0.1) }  // ≥ minSpeech
        #expect(ep.process(speechStarted: false, speechEnded: true, sentenceEnded: false, dt: 0.1).contains(.finalize))
        #expect(ep.inUtterance == false)
    }

    @Test func tooShortIsDroppedNotFinalized() {
        var ep = Endpointer(config: .init(minSpeech: 0.30, maxSpeech: 10))
        _ = ep.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.1)  // 0.1s only
        let ev = ep.process(speechStarted: false, speechEnded: true, sentenceEnded: false, dt: 0.1)  // end too soon
        #expect(ev.contains(.finalize) == false)
        #expect(ep.inUtterance == false)
    }

    @Test func maxSpeechCapFlushes() {
        var ep = Endpointer(config: .init(minSpeech: 0.30, maxSpeech: 10))
        _ = ep.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.1)
        var finalized = false
        for _ in 0..<200 where !finalized {  // nonstop voice, no speechEnd
            finalized = ep.process(speechStarted: false, speechEnded: false, sentenceEnded: false, dt: 0.1).contains(.finalize)
        }
        #expect(finalized)
    }

    @Test func sentencePunctuationClosesAfterMinSpeech() {
        var ep = Endpointer(config: .init(minSpeech: 0.30, maxSpeech: 10))
        _ = ep.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.1)
        for _ in 0..<4 { _ = ep.process(speechStarted: false, speechEnded: false, sentenceEnded: false, dt: 0.1) }
        #expect(ep.process(speechStarted: false, speechEnded: false, sentenceEnded: true, dt: 0.1).contains(.finalize))
    }

    @Test func punctuationBeforeMinSpeechIsIgnored() {
        var ep = Endpointer(config: .init(minSpeech: 0.30, maxSpeech: 10))
        _ = ep.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.1)
        #expect(ep.process(speechStarted: false, speechEnded: false, sentenceEnded: true, dt: 0.1).isEmpty)
    }

    @Test func endsSentenceDetection() {
        #expect(Endpointer.endsSentence("Hello."))
        #expect(Endpointer.endsSentence("好的。"))
        #expect(Endpointer.endsSentence("really?"))
        #expect(!Endpointer.endsSentence("hello"))
        #expect(!Endpointer.endsSentence(""))
    }

    @Test func settingsRoundTripWithoutVadMode() throws {
        let data = try JSONEncoder().encode(CaptionSettings.default)
        let back = try JSONDecoder().decode(CaptionSettings.self, from: data)
        #expect(back == CaptionSettings.default)
        let legacy: CaptionSettings = try JSONDecoder().decode(CaptionSettings.self, from: Data("{}".utf8))
        #expect(legacy == CaptionSettings.default)
    }
}

/// Sentence length, and the grace it buys.
///
/// The defect: caption lines two characters long. A speaker pausing after "然後"
/// or "好的" hit the acoustic endpoint with a fragment that reads as complete, so
/// the semantic check had nothing to object to and it became its own line.
@Suite struct SentenceLengthTests {

    @Test func twoChineseCharactersAreNotASentence() {
        #expect(!Endpointer.isSentenceLength("然後"))
        #expect(!Endpointer.isSentenceLength("好的"))
        #expect(!Endpointer.isSentenceLength("對啊"))
    }

    @Test func aRealChineseSentenceIs() {
        #expect(Endpointer.isSentenceLength("我知道了"))
        #expect(Endpointer.isSentenceLength("把重試機制加到上傳器"))
    }

    /// The unit differs by script: two Latin characters is a whole answer.
    @Test func shortEnglishRepliesStillCount() {
        #expect(Endpointer.isSentenceLength("OK"))
        #expect(Endpointer.isSentenceLength("Yes"))
    }

    @Test func emptyIsNotASentence() {
        #expect(!Endpointer.isSentenceLength(""))
        #expect(!Endpointer.isSentenceLength("  "))
    }

    /// "Not a sentence" and "too short to close on" are different claims, and the
    /// call site conflated them: with no partial at all there is nothing to judge,
    /// so a silent VAD blip must not spend the utterance's only deferral.
    @Test func nothingHeardYetIsNotTooShort() {
        #expect(!Endpointer.isTooShortToClose(""))
        #expect(!Endpointer.isTooShortToClose("   "))
        #expect(!Endpointer.isTooShortToClose("。"))     // punctuation, no content
        #expect(Endpointer.isTooShortToClose("然後"))
        #expect(!Endpointer.isTooShortToClose("我知道了"))
    }

    /// The whole reason it matters: a cough that outlasts `minSpeech` before the
    /// recognizer says anything used to burn the grace, and `graceUsed` only
    /// resets on the next `.start` — which never comes, because the blip already
    /// opened the utterance. Real speech then got cut at its first pause.
    @Test func aSilentBlipLeavesTheGraceIntact() {
        var endpointer = Endpointer(config: .init(
            minSpeech: 0.2, maxSpeech: 10, maxGraceEndings: 1
        ))
        _ = endpointer.process(speechStarted: true, speechEnded: false,
                               sentenceEnded: false, dt: 0.3)
        // The blip ends with no partial text at all.
        let blip = endpointer.process(
            speechStarted: false, speechEnded: true, sentenceEnded: false,
            tooShort: Endpointer.isTooShortToClose(""), dt: 0.1
        )
        #expect(blip.contains(.finalize))   // closed, and the grace was never touched

        // A fresh utterance, now with real speech that ends mid-thought: the
        // grace is still available to hold it open.
        _ = endpointer.process(speechStarted: true, speechEnded: false,
                               sentenceEnded: false, dt: 0.3)
        let held = endpointer.process(speechStarted: false, speechEnded: true,
                                      sentenceEnded: false, sentenceIncomplete: true, dt: 0.1)
        #expect(held.isEmpty)
    }

    /// It defers a close, it does not veto one — a genuine short reply still
    /// lands, one silence window later.
    @Test func graceIsSpentThenTheCloseHappens() {
        var endpointer = Endpointer(config: .init(
            minSpeech: 0.2, maxSpeech: 10, maxGraceEndings: 1
        ))
        _ = endpointer.process(speechStarted: true, speechEnded: false,
                               sentenceEnded: false, dt: 0.3)
        // First silence: held open because the text is too short.
        let first = endpointer.process(speechStarted: false, speechEnded: true,
                                       sentenceEnded: false, tooShort: true, dt: 0.1)
        #expect(first.isEmpty)
        // Second: the grace is spent, so it finalizes rather than hanging forever.
        let second = endpointer.process(speechStarted: false, speechEnded: true,
                                        sentenceEnded: false, tooShort: true, dt: 0.1)
        #expect(second.contains(.finalize))
    }
}
