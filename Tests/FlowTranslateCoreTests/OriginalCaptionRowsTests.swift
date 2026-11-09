import Testing
@testable import FlowTranslateCore

@Suite struct OriginalCaptionRowsTests {
    @Test func sentenceBreakWaitsForStablePunctuation() {
        var caption = OriginalCaptionRows()
        caption.update("Let's start.", fits: { _ in true })
        #expect(caption.rows == ["Let's start."])
        caption.update("Let's start. Next is the report.", fits: { _ in true })
        #expect(caption.rows == ["Let's start.", "Next is the report."])
    }

    @Test func punctuationAndTheNextSentenceCanArriveTogether() {
        var caption = OriginalCaptionRows()
        caption.update("The report is ready", fits: { _ in true })
        caption.update("The report is ready. Can we send it?", fits: { _ in true })
        #expect(caption.rows == ["The report is ready.", "Can we send it?"])
    }

    @Test func wrappingDoesNotPullAlreadyDisplayedWordsToTheNextRow() {
        var caption = OriginalCaptionRows()
        caption.update("We read the report, and", fits: { $0.count <= 25 })
        caption.update("We read the report, and now we decide.", fits: { $0.count <= 25 })
        #expect(caption.rows == ["We read the report, and", "now we decide."])
    }

    @Test func protectedDotsAndClosingQuotesStayInTheirSentence() {
        var caption = OriginalCaptionRows()
        caption.update("Dr. Chen checked v1.4.1 at 3.14 p.m. today. She asked, \"Ready?\" Yes.",
                       final: true, fits: { _ in true })
        #expect(caption.rows == [
            "Dr. Chen checked v1.4.1 at 3.14 p.m. today.", "She asked, \"Ready?\"", "Yes."
        ])
    }

    @Test func chineseSentenceBreakKeepsItsClosingQuote() {
        var caption = OriginalCaptionRows()
        caption.update("陳先生說：「可以嗎？」", fits: { _ in true })
        caption.update("陳先生說：「可以嗎？」當然可以！", fits: { _ in true })
        #expect(caption.rows == ["陳先生說：「可以嗎？」", "當然可以！"])
    }

    @Test func finalCorrectionChangesOnlyTheOpenRow() {
        var caption = OriginalCaptionRows()
        caption.update("We reviewed the budget. Next is the report.", final: true, fits: { _ in true })
        caption.update("We carefully reviewed the budget. Next is the deadline.",
                       final: true, fits: { _ in true })
        #expect(caption.rows == ["We reviewed the budget.", "Next is the deadline."])
    }

    @Test func finalCanRetractOnlyTheOpenTail() {
        var caption = OriginalCaptionRows()
        caption.update("First sentence. Second sentence. Wrong tail", fits: { _ in true })
        caption.update("First sentence. Second sentence.", final: true, fits: { _ in true })
        caption.update("First sentence. Second sentence.", final: true, fits: { _ in true })
        #expect(caption.rows == ["First sentence.", "Second sentence."])
    }

    @Test func longSentenceWrapsWithoutDroppingWords() {
        var caption = OriginalCaptionRows()
        caption.update("We read the report, and now we can decide together.",
                       fits: { $0.count <= 20 })
        #expect(caption.rows == ["We read the report,", "and now we can", "decide together."])
    }
}
