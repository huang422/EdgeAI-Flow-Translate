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
