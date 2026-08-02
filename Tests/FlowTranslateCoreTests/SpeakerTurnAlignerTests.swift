import Testing
@testable import FlowTranslateCore

@Suite struct SpeakerTurnAlignerTests {
    @Test func splitsTokensAtSpeakerChange() {
        let tokens = [
            TimedTextToken(text: "▁Hello", startTime: 0.0, endTime: 0.4),
            TimedTextToken(text: "▁there", startTime: 0.4, endTime: 0.9),
            TimedTextToken(text: ".", startTime: 0.9, endTime: 1.0),
            TimedTextToken(text: "▁Hi", startTime: 1.1, endTime: 1.4),
            TimedTextToken(text: "!", startTime: 1.4, endTime: 1.5),
        ]
        let turns = [
            SpeakerTurn(label: "Speaker 1", startTime: 0, endTime: 1.05),
            SpeakerTurn(label: "Speaker 2", startTime: 1.05, endTime: 2),
        ]

        let result = SpeakerTurnAligner.align(tokens: tokens, turns: turns)

        #expect(result.count == 2)
        #expect(result[0].text == "Hello there.")
        #expect(result[0].speakerLabel == "Speaker 1")
        #expect(result[1].text == "Hi!")
        #expect(result[1].speakerLabel == "Speaker 2")
    }

    @Test func firstTokenOutsideEveryTurnIsKept() {
        // The crash case: diarization turns come from a separately buffered audio
        // slice, so the opening token routinely falls outside all of them. With no
        // turn and no previous label it is unlabelled — which used to compare
        // equal to an empty group's nil label and index groups[-1].
        let tokens = [
            TimedTextToken(text: "▁Sorry", startTime: 0.0, endTime: 0.3),
            TimedTextToken(text: "▁go", startTime: 0.9, endTime: 1.2),
            TimedTextToken(text: "▁ahead", startTime: 1.2, endTime: 1.6),
        ]
        let turns = [SpeakerTurn(label: "Speaker 1", startTime: 0.8, endTime: 2.0)]

        let result = SpeakerTurnAligner.align(tokens: tokens, turns: turns)

        // The unlabelled opening stays its own group; nothing is dropped.
        #expect(result.count == 2)
        #expect(result[0].text == "Sorry")
        #expect(result[0].speakerLabel == nil)
        #expect(result[1].text == "go ahead")
        #expect(result[1].speakerLabel == "Speaker 1")
    }

    @Test func allTokensOutsideEveryTurnStayOneUnlabelledGroup() {
        // Every token unlabelled — the empty-groups comparison would trap on the
        // very first one, so this never even reached the second.
        let tokens = [
            TimedTextToken(text: "▁Hello", startTime: 10, endTime: 10.4),
            TimedTextToken(text: "▁there", startTime: 10.4, endTime: 10.9),
        ]
        let turns = [SpeakerTurn(label: "Speaker 1", startTime: 0, endTime: 1)]

        let result = SpeakerTurnAligner.align(tokens: tokens, turns: turns)

        #expect(result.count == 1)
        #expect(result[0].text == "Hello there")
        #expect(result[0].speakerLabel == nil)
    }

    @Test func punctuationInheritsTheMeasuredSpeaker() {
        let tokens = [
            TimedTextToken(text: "▁Testing", startTime: 2, endTime: 2.4),
            TimedTextToken(text: ".", startTime: 2.4, endTime: 2.4),
        ]
        let turns = [SpeakerTurn(label: "Speaker 1", startTime: 2, endTime: 3)]

        let result = SpeakerTurnAligner.align(tokens: tokens, turns: turns)

        #expect(result.count == 1)
        #expect(result[0].text == "Testing.")
        #expect(result[0].speakerLabel == "Speaker 1")
    }
}
