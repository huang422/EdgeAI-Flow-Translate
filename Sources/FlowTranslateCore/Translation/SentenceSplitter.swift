import Foundation

/// Splits a finalized utterance into sentences, keeping terminal punctuation, so
/// the transcript and the overlay present one sentence at a time.
///
/// Pure value logic — fully unit-testable.
public enum SentenceSplitter {

    static let terminators: Set<Character> = [".", "?", "!", "。", "！", "？", "…"]

    /// Sentences in order. Returns an empty array when the text says nothing —
    /// callers must treat that as "discard this utterance" rather than committing
    /// an empty caption.
    public static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            current.append(chars[i])
            // Close on a terminator ONLY once the segment actually says
            // something, and then swallow the whole run of terminators that
            // follows. Closing on every one of them turned "Wait...!" into
            // "Wait." + "." + "." + "!" — three caption lines made of nothing but
            // punctuation, exactly the kind of empty line that reads as a glitch.
            guard terminators.contains(chars[i]), saysSomething(current) else {
                i += 1
                continue
            }
            var j = i + 1
            while j < chars.count, terminators.contains(chars[j]) {
                current.append(chars[j])
                j += 1
            }
            i = j
            let closed = trimmingLeadingNoise(current)
            if !closed.isEmpty { sentences.append(closed) }
            current = ""
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return sentences }
        if saysSomething(tail) {
            let trimmed = trimmingLeadingNoise(tail)
            if !trimmed.isEmpty { sentences.append(trimmed) }
        } else if !sentences.isEmpty {
            // Dangling punctuation belongs to the sentence it followed, not to a
            // line of its own.
            sentences[sentences.count - 1] += tail
        }
        // An utterance that was ONLY punctuation yields nothing at all.
        return sentences
    }

    /// Whether a segment carries any actual content, as opposed to punctuation
    /// and spacing.
    static func saysSomething(_ s: String) -> Bool {
        s.contains { $0.isLetter || $0.isNumber }
    }

    /// Drop leading spaces and stray terminators so a sentence that followed a
    /// doubled full stop doesn't open with one.
    static func trimmingLeadingNoise(_ s: String) -> String {
        var out = Substring(s)
        while let f = out.first, f.isWhitespace || terminators.contains(f) {
            out = out.dropFirst()
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
