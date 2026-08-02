import Testing
@testable import FlowTranslateCore

@Suite struct SemanticEndpointTests {

    // MARK: - English danglers

    @Test func danglingConjunctionIsIncomplete() {
        #expect(SemanticEndpoint.isIncomplete("we should do this because"))
        #expect(SemanticEndpoint.isIncomplete("I want to"))
        #expect(SemanticEndpoint.isIncomplete("it depends on the"))
        #expect(SemanticEndpoint.isIncomplete("we're going to"))
    }

    @Test func completeSentencesAreNotIncomplete() {
        #expect(!SemanticEndpoint.isIncomplete("we should ship it today"))
        #expect(!SemanticEndpoint.isIncomplete("that's what it is."))
        #expect(!SemanticEndpoint.isIncomplete("are you ready?"))
    }

    /// Terminal punctuation always wins, even after a dangler-looking word.
    @Test func terminalPunctuationWins() {
        #expect(!SemanticEndpoint.isIncomplete("I know what this is."))
        #expect(!SemanticEndpoint.isIncomplete("好，就這樣。"))
    }

    @Test func trailingCommaIsIncomplete() {
        #expect(SemanticEndpoint.isIncomplete("first we gather the data,"))
        #expect(SemanticEndpoint.isIncomplete("首先，"))
        #expect(SemanticEndpoint.isIncomplete("第一、"))
    }

    @Test func caseInsensitiveLookup() {
        #expect(SemanticEndpoint.isIncomplete("And then we saw AND"))
        #expect(SemanticEndpoint.isIncomplete("The plan is TO"))
    }

    // MARK: - Chinese danglers

    @Test func chineseConnectivesAreIncomplete() {
        #expect(SemanticEndpoint.isIncomplete("我們先做這個然後"))
        #expect(SemanticEndpoint.isIncomplete("這樣做是因為"))
        #expect(SemanticEndpoint.isIncomplete("成本很高所以"))
    }

    @Test func chineseCompleteSentences() {
        #expect(!SemanticEndpoint.isIncomplete("我們明天再討論"))
        #expect(!SemanticEndpoint.isIncomplete("好的沒問題"))
    }

    // MARK: - Edges

    @Test func emptyAndWhitespaceAreComplete() {
        #expect(!SemanticEndpoint.isIncomplete(""))
        #expect(!SemanticEndpoint.isIncomplete("   "))
    }

    /// Words that merely CONTAIN a dangler must not match ("band" vs "and").
    @Test func noSubstringFalsePositives() {
        #expect(!SemanticEndpoint.isIncomplete("we formed a band"))
        #expect(!SemanticEndpoint.isIncomplete("that was withheld"))
    }
}

@Suite struct EndpointerGraceTests {
    private func cfg(minSpeech: Double = 0.3, maxSpeech: Double = 8,
                     grace: Int = 1) -> EndpointerConfig {
        EndpointerConfig(minSpeech: minSpeech, maxSpeech: maxSpeech, maxGraceEndings: grace)
    }

    /// A VAD endpoint on an unfinished sentence is deferred once, then the next
    /// endpoint finalizes even if still "incomplete".
    @Test func acousticEndpointDeferredOnceThenFinalizes() {
        var e = Endpointer(config: cfg())
        _ = e.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.5)
        // First endpoint: text ends in "because" → deferred, utterance stays open.
        let deferred = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                                 sentenceIncomplete: true, dt: 0.1)
        #expect(deferred.isEmpty)
        #expect(e.inUtterance)
        // Speaker continues, then a second endpoint (still incomplete) finalizes.
        _ = e.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 1.0)
        let final = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                              sentenceIncomplete: true, dt: 0.1)
        #expect(final == [.finalize])
        #expect(!e.inUtterance)
    }

    /// A complete-sounding sentence is NOT deferred.
    @Test func completeSentenceFinalizesImmediately() {
        var e = Endpointer(config: cfg())
        _ = e.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.5)
        let events = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                               sentenceIncomplete: false, dt: 0.1)
        #expect(events == [.finalize])
    }

    /// Sub-minSpeech blips are still dropped, incomplete or not.
    @Test func blipStillDropsRegardlessOfSemantics() {
        var e = Endpointer(config: cfg())
        _ = e.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.1)
        let events = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                               sentenceIncomplete: true, dt: 0.05)
        #expect(events.isEmpty)
        #expect(!e.inUtterance)
    }

    /// The wall-clock cap still fires during a grace hold (a non-stop talker
    /// can't keep the line open forever).
    @Test func maxSpeechCapStillAppliesAfterGrace() {
        var e = Endpointer(config: cfg(maxSpeech: 2))
        _ = e.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.5)
        _ = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                      sentenceIncomplete: true, dt: 0.1)   // deferred
        let events = e.process(speechStarted: false, speechEnded: false, sentenceEnded: false,
                               sentenceIncomplete: true, dt: 2.0)   // blows past the cap
        #expect(events == [.finalize])
    }

    /// Grace budget resets for the next utterance.
    @Test func graceBudgetResetsPerUtterance() {
        var e = Endpointer(config: cfg())
        _ = e.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.5)
        _ = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                      sentenceIncomplete: true, dt: 0.1)   // grace used
        _ = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                      sentenceIncomplete: true, dt: 0.1)   // finalize (budget spent)
        // New utterance gets a fresh grace budget.
        _ = e.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.5)
        let deferred = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                                 sentenceIncomplete: true, dt: 0.1)
        #expect(deferred.isEmpty)
        #expect(e.inUtterance)
    }

    /// maxGraceEndings = 0 disables the semantic hold entirely.
    @Test func zeroGraceBehavesLikeBefore() {
        var e = Endpointer(config: cfg(grace: 0))
        _ = e.process(speechStarted: true, speechEnded: false, sentenceEnded: false, dt: 0.5)
        let events = e.process(speechStarted: false, speechEnded: true, sentenceEnded: false,
                               sentenceIncomplete: true, dt: 0.1)
        #expect(events == [.finalize])
    }
}
