import Foundation

/// Assembles a dictation's final text out of the recognizer's finalized segments
/// and whatever was still volatile when the user stopped.
///
/// Pure value logic so it can be tested. Inside the dictation controller this
/// decision produced two text-corruption bugs — a spurious space inside every CJK
/// sentence, then a duplicated last sentence — both invisible to inspection and
/// both a three-line test.
public enum DictationTranscriptAssembler {

    /// Join two recognizer segments the way the running engine needs them joined.
    ///
    /// **The engine's contract decides, not a guess about the characters.**
    /// Apple's `DictationTranscriber` segments carry their own leading space, so
    /// adding a separator puts one inside a Chinese sentence; Nemotron's bare
    /// words need one. A script-aware heuristic cannot tell which it is looking
    /// at, and is wrong in both directions.
    public static func join(
        _ left: String,
        _ right: String,
        segmentsCarryOwnSpacing: Bool
    ) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        return segmentsCarryOwnSpacing ? left + right : "\(left) \(right)"
    }

    /// The text to insert, given the finalized transcript and the interim that was
    /// in flight when the user stopped.
    ///
    /// A dictation ends *while* the last utterance is still volatile, so the
    /// interim has to be kept — dropping it loses whole dictations, since a
    /// dictation is frequently only that one sentence. But the drain usually does
    /// finalize it, and then appending it duplicates it.
    ///
    /// - Parameter drainProducedText: whether any finalized segment arrived after
    ///   the interim was set aside. This, not a substring test, is what decides.
    ///   A volatile result and the final it becomes are *supposed* to differ —
    ///   finalizing is where wording, punctuation and capitalization get revised —
    ///   so a `contains` check fails precisely when the drain worked, and appends
    ///   a second, worse copy of the user's last sentence.
    public static func assemble(
        transcript: String,
        carriedInterim: String,
        drainProducedText: Bool,
        segmentsCarryOwnSpacing: Bool
    ) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let carried = carriedInterim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !carried.isEmpty else { return spoken }
        // The drain superseded it.
        guard !drainProducedText else { return spoken }
        // Nothing was finalized after the interim — but it may have been finalized
        // *before* the user pressed the key. Whitespace cannot decide that either,
        // so it is stripped from both sides before comparing.
        guard !strippingWhitespace(spoken).contains(strippingWhitespace(carried))
        else { return spoken }
        return join(spoken, carried, segmentsCarryOwnSpacing: segmentsCarryOwnSpacing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` with every space, tab and newline removed.
    static func strippingWhitespace(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}
