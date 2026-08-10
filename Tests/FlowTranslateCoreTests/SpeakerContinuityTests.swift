import Testing
@testable import FlowTranslateCore

/// The reported symptom is "speaker detection sometimes just has no result".
///
/// It is not random. The diarizer runs with `minSpeechDuration: 1.0`, so a
/// segment below that returns no speaker at all — and the comment that sets it
/// says this is fine "because the aligner's `previousLabel` fallback is for"
/// exactly that. But that fallback lives *inside* one utterance. When pyannote
/// produced no turn for the whole utterance, `dominantSpeaker` was handed an
/// empty array, returned nil, and the sentence went out unlabelled. Short
/// replies — "對", "OK", "沒問題" — are precisely the utterances that fall under
/// the threshold, and they are a large share of a meeting.
@Suite("Speaker continuity across an unlabelled utterance")
struct SpeakerContinuityTests {

    @Test("a diarized label passes straight through and is remembered")
    func resolvedLabelWins() {
        var continuity = SpeakerContinuity()
        #expect(continuity.label("Speaker 1", from: 0, to: 4) == "Speaker 1")
        // The short one right after inherits it.
        #expect(continuity.label(nil, from: 4.2, to: 4.9) == "Speaker 1")
    }

    /// The case that was losing its name.
    @Test("a short unlabelled reply inherits the current speaker")
    func shortReplyInherits() {
        var continuity = SpeakerContinuity()
        _ = continuity.label("Speaker 2", from: 0, to: 5)
        #expect(continuity.label(nil, from: 5.1, to: 5.6) == "Speaker 2")
    }

    /// A long utterance the diarizer failed on is a different failure, and
    /// attributing a whole paragraph to whoever spoke last is worse than a blank.
    @Test("a long unlabelled utterance is left unlabelled")
    func longUtteranceDoesNotInherit() {
        var continuity = SpeakerContinuity()
        _ = continuity.label("Speaker 1", from: 0, to: 5)
        #expect(continuity.label(nil, from: 5.1, to: 12) == nil)
    }

    /// After a real pause the next voice is as likely to be someone else, and a
    /// stale name is a confident lie where a blank is only unhelpful.
    @Test("a stale speaker is not carried across a long silence")
    func staleSpeakerExpires() {
        var continuity = SpeakerContinuity()
        _ = continuity.label("Speaker 1", from: 0, to: 5)
        #expect(continuity.label(nil, from: 20, to: 20.5) == nil)
    }

    /// A run of backchannels keeps inheriting: each one extends the run, so the
    /// third does not age out against the last *diarized* utterance.
    @Test("consecutive short replies keep the label")
    func consecutiveShortRepliesKeepTheLabel() {
        var continuity = SpeakerContinuity()
        _ = continuity.label("Speaker 3", from: 0, to: 4)
        #expect(continuity.label(nil, from: 4.5, to: 5.0) == "Speaker 3")
        #expect(continuity.label(nil, from: 7.5, to: 8.0) == "Speaker 3")
        #expect(continuity.label(nil, from: 10.5, to: 11.0) == "Speaker 3")
    }

    @Test("nothing is inherited before the first diarized utterance")
    func nothingToInheritAtTheStart() {
        var continuity = SpeakerContinuity()
        #expect(continuity.label(nil, from: 0, to: 0.5) == nil)
    }

    /// A new meeting must not inherit the last one's name — the speaker database
    /// behind that label has been reset.
    @Test("reset forgets the previous speaker")
    func resetForgets() {
        var continuity = SpeakerContinuity()
        _ = continuity.label("Speaker 1", from: 0, to: 5)
        continuity.reset()
        #expect(continuity.label(nil, from: 5.1, to: 5.6) == nil)
    }

    /// A later diarized answer always overrides the inherited one — inheritance
    /// is a fallback, never a preference.
    @Test("a new diarized label takes over from an inherited one")
    func diarizedLabelOverridesInherited() {
        var continuity = SpeakerContinuity()
        _ = continuity.label("Speaker 1", from: 0, to: 4)
        #expect(continuity.label(nil, from: 4.2, to: 4.8) == "Speaker 1")
        #expect(continuity.label("Speaker 2", from: 5, to: 9) == "Speaker 2")
        #expect(continuity.label(nil, from: 9.2, to: 9.8) == "Speaker 2")
    }
}
