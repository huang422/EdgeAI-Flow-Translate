import Foundation

/// A request split into lines and then into sentences, so a repair pass can work
/// one sentence at a time without reflowing what the user wrote.
///
/// Splitting the whole request with `SentenceSplitter.split` and rejoining on a
/// space does not survive contact with how people write these. Sentence splitting
/// does not treat a newline as a boundary, so two lines with no terminal
/// punctuation become one sentence and the join flattens the rest — a five-line
/// request comes back as three lines of wrapped text, with one-requirement-per-
/// line structure gone. A tidy pass fixes characters, it does not re-flow
/// paragraphs.
///
/// So the line structure is captured before splitting and restored afterwards.
/// Blank lines are kept as blank lines: a blank line between two paragraphs is
/// content.
public struct RequestOutline: Sendable, Equatable {

    /// Sentences per line, in order. An empty inner array is a blank line.
    public let lines: [[String]]

    public init(_ text: String) {
        lines = text
            .components(separatedBy: .newlines)
            .map { line in
                let sentences = SentenceSplitter.split(line)
                // A line the splitter yields nothing for is **not** a blank line.
                // `split` drops anything with no letter or digit in it, which is
                // right for a caption — a punctuation-only utterance is noise —
                // and destructive here, where the text has to come back exactly
                // as the user wrote it. A ``` fence, a `---` rule or a row of
                // `===` would otherwise be replaced with an empty line by
                // `rejoined`, breaking the block it delimits, and `tidyTranscript`
                // writes that result back over the request.
                //
                // Kept whole rather than split. Nothing downstream will repair it
                // either: `PromptRepairGate.shouldAttempt` skips a line with no
                // content, so it round-trips untouched, which is the correct
                // outcome for a delimiter.
                if sentences.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    return [line]
                }
                return sentences
            }
    }

    /// Every sentence across every line, in reading order — what a repair pass
    /// iterates over.
    public var sentences: [String] { lines.flatMap { $0 } }

    /// Rebuild the request from repaired sentences, restoring the original line
    /// structure.
    ///
    /// `repaired` must be the result of mapping over `sentences` one-for-one; a
    /// shorter list falls back to the original sentence for the remainder, so a
    /// cancelled pass cannot silently delete the tail of a request.
    public func rejoined(with repaired: [String]) -> String {
        var cursor = 0
        var output: [String] = []
        for line in lines {
            var pieces: [String] = []
            for original in line {
                pieces.append(cursor < repaired.count ? repaired[cursor] : original)
                cursor += 1
            }
            output.append(pieces.joined(separator: " "))
        }
        // Trailing blank lines are an artifact of where the caret happened to be,
        // not content worth preserving.
        while let last = output.last, last.isEmpty { output.removeLast() }
        return output.joined(separator: "\n")
    }
}
