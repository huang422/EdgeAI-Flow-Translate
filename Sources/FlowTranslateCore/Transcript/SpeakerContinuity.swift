import Foundation

/// Carries the last known speaker across an utterance the diarizer could not
/// label.
///
/// **The gap this closes.** `SpeakerTurnAligner` falls back to the previous label
/// only *within* one utterance. When pyannote returns no usable turn for the
/// whole utterance the label was dropped entirely — and that happens by design
/// for anything under `minSpeechDuration: 1.0`, so every "對", "OK", "沒問題" lost
/// its name. In a conversation that reads as the feature failing at random.
///
/// **Why inheriting is safe here and only here.** Two bounds, both required:
///
/// - The utterance has to be *short*. A long utterance the diarizer failed on is
///   a different problem — a thrown inference, an empty buffer — and attributing
///   a whole paragraph to whoever spoke last is a worse error than showing no
///   name at all.
/// - The previous label has to be *recent*. After a real pause the next voice is
///   as likely to be someone else, and a stale name is a confident lie where a
///   blank is merely unhelpful.
///
/// Outside those bounds it returns nil and the label stays absent, which is the
/// behaviour that was always correct for the long-utterance case.
///
/// Pure value logic — no diarizer, no clock, fully unit-testable.
public struct SpeakerContinuity: Sendable, Equatable {

    /// Longest utterance that may inherit a label.
    ///
    /// Above the diarizer's own `minSpeechDuration` of 1.0 s with a little room,
    /// because the utterance clock and pyannote's segment clock do not measure the
    /// same thing: the endpointer's span includes the leading and trailing silence
    /// inside the VAD window, so a sub-second *speech* segment routinely presents
    /// as a slightly longer utterance.
    public static let maxCarryOverDuration: TimeInterval = 1.5

    /// Longest silence after the previous labelled speech that still counts as
    /// the same turn. Beyond it, who is talking is genuinely an open question.
    public static let maxCarryOverGap: TimeInterval = 3.0

    private var lastLabel: String?
    private var lastEnd: TimeInterval = -.greatestFiniteMagnitude

    public init() {}

    /// The label to attach to an utterance, given what the diarizer resolved.
    ///
    /// Pass the diarizer's answer — `nil` when it produced none — and get back
    /// either that answer, an inherited one, or `nil`.
    public mutating func label(
        _ resolved: String?, from start: TimeInterval, to end: TimeInterval
    ) -> String? {
        if let resolved {
            lastLabel = resolved
            lastEnd = end
            return resolved
        }
        guard let lastLabel,
              end - start <= Self.maxCarryOverDuration,
              start - lastEnd <= Self.maxCarryOverGap
        else { return nil }
        // Extend the run, so a series of short backchannels keeps inheriting
        // instead of ageing out against the last *diarized* utterance.
        lastEnd = end
        return lastLabel
    }

    /// Forget the previous speaker. Called when the pipeline resets, so a new
    /// meeting never inherits the last one's name.
    public mutating func reset() {
        lastLabel = nil
        lastEnd = -.greatestFiniteMagnitude
    }
}
