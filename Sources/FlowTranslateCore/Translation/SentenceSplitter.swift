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
            guard terminators.contains(chars[i]), saysSomething(current),
                  !isWordInternalDot(chars, i)
            else {
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
        guard !tail.isEmpty else { return mergingFragments(sentences) }
        if saysSomething(tail) {
            let trimmed = trimmingLeadingNoise(tail)
            if !trimmed.isEmpty { sentences.append(trimmed) }
        } else if !sentences.isEmpty {
            // Dangling punctuation belongs to the sentence it followed, not to a
            // line of its own.
            sentences[sentences.count - 1] += tail
        }
        // An utterance that was ONLY punctuation yields nothing at all.
        return mergingFragments(sentences)
    }

    /// Fewer content characters than this and a sentence cannot stand as its own
    /// caption line.
    ///
    /// One character is the whole complaint: "好。我們明天再討論。" is two correct
    /// sentences and one wrong caption — a line reading `好。` flashes past before
    /// it can be read, gets its own translation request, and its own row in the
    /// transcript. Two is left alone: "好的。" and "Yes." are short but readable.
    static let minContentCharacters = 2

    /// Attach one-character sentences to a neighbour.
    ///
    /// An acknowledgement leads what follows it ("好。我們開始。"), so a fragment
    /// merges **forward** into the next sentence; only a trailing one merges back.
    /// A fragment that is the entire utterance is left alone — the alternative is
    /// dropping something the speaker said.
    static func mergingFragments(_ sentences: [String]) -> [String] {
        guard sentences.count > 1 else { return sentences }
        var result: [String] = []
        var pending = ""   // fragments waiting to lead the next real sentence
        for sentence in sentences {
            guard TextCounting.contentCharacters(sentence) >= minContentCharacters else {
                pending = pending.isEmpty ? sentence : join(pending, sentence)
                continue
            }
            result.append(pending.isEmpty ? sentence : join(pending, sentence))
            pending = ""
        }
        guard !pending.isEmpty else { return result }
        // A trailing fragment goes back onto the previous line rather than
        // becoming one of its own.
        if let last = result.popLast() {
            result.append(join(last, pending))
        } else {
            result.append(pending)   // every sentence was a fragment
        }
        return result
    }

    /// Join two sentences the way the script writes them.
    ///
    /// Decided by the *left* side alone. Full-width punctuation (`。！？`) carries
    /// its own trailing space in the glyph, so anything after it runs flush —
    /// including a Latin word. An ASCII full stop does not, so it always takes a
    /// space, including before Chinese. Looking at both sides instead produced
    /// `A.我們開始` for the one mixed-script case where a space is wanted.
    static func join(_ left: String, _ right: String) -> String {
        guard let last = left.last else { return right }
        return TokenEstimator.isCJK(last) ? left + right : left + " " + right
    }


    /// Whether the `.` at `i` sits inside a word rather than ending a sentence.
    ///
    /// A full stop that is immediately followed by a letter or digit, with no
    /// space, is never a sentence boundary in any language this app handles —
    /// it is a file extension, a version, a decimal or a domain. Without this,
    /// `Sources/Uploader.swift, it currently fails` split into
    /// `…Sources/Uploader.` and `swift, it currently fails`, which is how a
    /// dictated file path became two half-sentences and the path stopped
    /// resolving.
    ///
    /// Scoped to the ASCII full stop on purpose. `。！？` are unambiguous
    /// terminators and are routinely written with no following space in Chinese,
    /// so applying this to them would merge sentences instead of protecting
    /// words. `?` and `!` do not appear inside identifiers.
    static func isWordInternalDot(_ chars: [Character], _ i: Int) -> Bool {
        guard chars[i] == "." else { return false }
        let next = i + 1
        guard next < chars.count else { return false }
        return chars[next].isLetter || chars[next].isNumber
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
