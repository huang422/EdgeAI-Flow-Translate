import Foundation

/// Matches the live translation of a whole utterance to the sentences that
/// utterance just split into.
///
/// Solves a visible flicker in the second caption. While a sentence is being
/// spoken the band shows a live translation of it; at finalize the utterance is
/// split into sentences and each gets its own accurate translation, which takes a
/// moment to arrive. Throwing the live text away in between blanks the Chinese
/// line for text the app has already translated — but a translation of the whole
/// utterance is not a translation of the one sentence left in the slot, so it has
/// to be split to match rather than simply kept.
///
/// Throwing it away was the right answer to the wrong question. A translation of
/// two sentences is not *unusable*, it is two translations concatenated: split it
/// the same way and each sentence gets its own. When the counts do not match —
/// the translator merged two clauses, or dropped a sentence boundary — there is
/// no honest pairing and the pending marker is correct after all.
public enum InterimTranslationPairing {

    /// One provisional translation per sentence, or nil when they cannot be
    /// paired honestly.
    ///
    /// Returning nil rather than guessing is the whole point: showing sentence
    /// two's translation under sentence one is worse than showing nothing, and
    /// unlike a blank it does not announce itself as temporary.
    public static func pair(interim: String, toSentenceCount count: Int) -> [String]? {
        let trimmed = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, count > 0 else { return nil }
        // One sentence in, one out: the live text describes it exactly.
        guard count > 1 else { return [trimmed] }

        let parts = SentenceSplitter.split(trimmed).filter { !$0.isEmpty }
        guard parts.count == count else { return nil }
        return parts
    }
}
