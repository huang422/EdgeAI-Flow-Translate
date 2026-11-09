import Foundation

/// Splits a long dictation into passages small enough to repair in one call.
///
/// One pass over the whole transcript is the point of the passage repairer, so
/// this exists only for the case where the whole transcript will not fit: a
/// several-minute dictation. The budget is deliberately generous — roughly two
/// minutes of speech — so that almost every dictation is a single chunk and the
/// one-pass benefits are the normal case rather than the lucky one.
///
/// **Self-correction across a chunk boundary is not handled.** If the speaker
/// abandons a thought in one chunk and corrects it in the next, the merge cannot
/// happen: the two calls never see each other, and stitching them would
/// reintroduce exactly the error-propagation the one-pass design exists to
/// remove. The mitigation is the chunk size, not a mechanism.
public enum PassageChunker {

    /// Estimated tokens per chunk.
    ///
    /// Sized against the decode budget rather than the context window: the model
    /// has 262K of context and no trouble reading more, but it has to *generate*
    /// the whole passage back, and generation is the wall-clock cost. 700 tokens
    /// in means ~700 tokens out, which is a handful of seconds on an M1 Pro.
    public static let budget = 700

    /// One chunk, with the whitespace that separated it from the next.
    ///
    /// The separator is carried rather than assumed, and that is the whole
    /// reason this type exists instead of `[String]`. The first version rejoined
    /// with `"\n"`, which is right for a boundary that *was* a line break and
    /// wrong for one inside an over-long line — and the hotkey transcript is a
    /// single line with no newlines in it at all (`QuickDictationController`
    /// joins finalized segments with a space), so every long dictation would have
    /// come back with newlines inserted at sentence boundaries the speaker never
    /// made.
    public struct Chunk: Sendable, Equatable {
        public let text: String
        /// What followed this chunk in the original — `"\n"`, `" "`, or empty at
        /// the end.
        public let separator: String
    }

    /// `text` split into chunks, each within `budget` where possible.
    ///
    /// Boundaries are **line breaks first**: a dictated list has one item per
    /// line, and cutting between items keeps each chunk a complete thought.
    /// A single line over budget falls back to sentence boundaries, and a single
    /// *sentence* over budget is emitted whole rather than cut mid-clause —
    /// exceeding the budget is a latency cost, while cutting a sentence in half
    /// hands the model a fragment and asks it to repair it.
    public static func chunks(_ text: String) -> [Chunk] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard TokenEstimator.estimate(text) > budget else {
            return [Chunk(text: text, separator: "")]
        }

        // Every piece of the original, each tagged with what followed it, so the
        // rejoin is exact by construction rather than by convention.
        var pieces: [Chunk] = []
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let separator = index == lines.count - 1 ? "" : "\n"
            guard TokenEstimator.estimate(line) > budget else {
                pieces.append(Chunk(text: line, separator: separator))
                continue
            }
            pieces.append(contentsOf: losslessSentences(line, trailing: separator))
        }

        var chunks: [Chunk] = []
        var current = ""
        var currentCost = 0
        // The separator that closed the previous piece — it either joins that
        // piece to the next inside this chunk, or becomes this chunk's own
        // separator when the chunk ends here. Either way it is carried, never
        // invented.
        var pending = ""
        // Whether this chunk has taken a piece yet, which is **not** the same
        // question as `current.isEmpty`. A blank line is a piece with empty
        // text, so testing the string treated the piece after it as the first
        // one and dropped the `pending` newline between them — losing a blank
        // line the speaker (or the typist) put there, and breaking the rejoin
        // identity below.
        var started = false

        for piece in pieces {
            let cost = TokenEstimator.estimate(piece.text)
            if currentCost > 0, currentCost + cost > budget {
                chunks.append(Chunk(text: current, separator: pending))
                current = ""
                currentCost = 0
                started = false
            }
            current += started ? pending + piece.text : piece.text
            started = true
            currentCost += cost
            pending = piece.separator
        }
        if started {
            chunks.append(Chunk(text: current, separator: pending))
        }
        return chunks
    }

    /// Caption splitting intentionally cleans text. Repair chunking must instead
    /// retain every original character, including CJK adjacency and whitespace.
    private static func losslessSentences(_ line: String, trailing: String) -> [Chunk] {
        let chars = Array(line)
        var result: [Chunk] = []
        var start = 0
        var i = 0
        while i < chars.count {
            guard SentenceSplitter.terminators.contains(chars[i]),
                  !SentenceSplitter.isWordInternalDot(chars, i) else {
                i += 1
                continue
            }
            var end = i + 1
            while end < chars.count, SentenceSplitter.terminators.contains(chars[end]) { end += 1 }
            var next = end
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            result.append(Chunk(text: String(chars[start..<end]),
                                separator: String(chars[end..<next]) + (next == chars.count ? trailing : "")))
            start = next
            i = next
        }
        if start < chars.count {
            result.append(Chunk(text: String(chars[start...]), separator: trailing))
        }
        return result
    }

    /// Put repaired chunks back together exactly as they came apart.
    ///
    /// `rejoin(chunks(text).map(\.text), chunks: chunks(text)) == text` for any
    /// input. If that is not an identity on untouched text, every guarantee
    /// downstream of it is void.
    public static func rejoin(_ repaired: [String], chunks: [Chunk]) -> String {
        zip(repaired, chunks).map { $0.0 + $0.1.separator }.joined()
    }

}
