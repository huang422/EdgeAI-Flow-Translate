import Foundation

/// Heuristic "the sentence isn't finished" detector for live partial text.
///
/// Streaming VAD endpoints fire on ACOUSTIC silence, but people pause mid-
/// sentence after connectives ("so", "because", "然後…") while thinking. Cutting
/// there splits one thought into two caption lines and degrades translation
/// input. Modern streaming APIs pair acoustic endpointers with a semantic
/// signal for exactly this reason; this is the display-side, dependency-free
/// version: when the partial ends in a word that almost never ends a sentence,
/// the endpointer defers ONE extra silence window (bounded by maxSpeech).
///
/// Deliberately conservative: only unambiguous danglers are listed — a false
/// "incomplete" costs one silence window of latency, a false "complete" splits
/// a sentence, so both lists stay small and safe.
public enum SemanticEndpoint {

    /// Whether the live partial strongly suggests the speaker isn't done.
    public static func isIncomplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // A trailing comma (either script) is an explicit "more coming".
        if let last = trimmed.last, ",，、".contains(last) { return true }

        // Terminal punctuation wins: the sentence IS complete.
        if let last = trimmed.last, ".?!。！？…".contains(last) { return false }

        // Chinese connective suffixes (multi-char words, checked as suffixes).
        for suffix in Self.danglingChineseSuffixes where trimmed.hasSuffix(suffix) {
            return true
        }

        // English: strip trailing punctuation from the last word and look it up.
        guard let lastWord = trimmed.split(whereSeparator: { $0.isWhitespace }).last else {
            return false
        }
        let normalized = lastWord.lowercased().trimmingCharacters(
            in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
        return Self.danglingEnglishWords.contains(normalized)
    }

    /// English words that essentially never end a sentence (conjunctions,
    /// prepositions, articles, auxiliaries mid-clause).
    static let danglingEnglishWords: Set<String> = [
        // conjunctions
        "and", "or", "but", "so", "because", "although", "though", "if", "unless",
        "while", "whereas", "than",
        // prepositions
        "to", "of", "in", "on", "at", "with", "for", "from", "into", "about",
        "onto", "over", "under", "between", "through", "during", "before", "after",
        "by", "as", "via", "per",
        // articles / determiners
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "their",
        // dangling auxiliaries / verbs that take a complement
        "is", "are", "was", "were", "be", "been", "being",
        "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "have", "has", "had", "do", "does", "did",
        "gonna", "wanna", "gotta", "let's", "i'm", "we're", "they're", "you're", "it's",
        "there's", "that's", "what's", "who's", "don't", "doesn't", "didn't", "can't",
        "won't", "isn't", "aren't", "wasn't", "weren't",
    ]

    /// Chinese connectives that signal an unfinished thought when trailing.
    static let danglingChineseSuffixes: [String] = [
        "因為", "所以", "但是", "可是", "不過", "然後", "接著", "還有", "或者", "或是",
        "以及", "而且", "就是", "如果", "雖然", "由於", "為了", "關於", "跟", "和", "與",
        "的時候", "然而", "並且", "例如", "比如",
    ]
}
