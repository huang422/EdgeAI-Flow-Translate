import Foundation

/// Display lines of one utterance. The last line may be revised until a new
/// one is opened. The transcript keeps the decoder's independent final text.
public struct OriginalCaptionRows: Equatable, Sendable {
    public private(set) var rows: [String] = []
    private var previous: [Character] = []
    private var consumed = 0
    private var hasOpenRow = false

    public init() {}

    /// A source can regain the floating display after another source spoke.
    /// Continue after what was already displayed, without moving its old rows.
    public func continuation() -> Self {
        var result = Self()
        result.previous = previous
        result.consumed = previous.count
        return result
    }

    public mutating func appendUnseenFinal(_ text: String, fits: (String) -> Bool) {
        var tail = continuation()
        tail.update(text, final: true, fits: fits)
        guard !tail.rows.isEmpty else { return }
        rows.append(contentsOf: tail.rows)
        previous = tail.previous
        consumed = tail.consumed
        hasOpenRow = tail.hasOpenRow
    }

    public mutating func update(
        _ text: String, final: Bool = false, fits: (String) -> Bool
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let next = Array(value)
        let shared = zip(previous, next).prefix { $0 == $1 }.count
        var cursor = consumed
        if shared < consumed {
            // Map the locked boundary into the new hypothesis so revisions to
            // already read words do not duplicate or drop the open suffix.
            let edits = next.difference(from: previous)
            let removed = edits.removals.count { change in
                if case let .remove(offset, _, _) = change { return offset < consumed }
                return false
            }
            cursor -= removed
            for change in edits.insertions {
                if case let .insert(offset, _, _) = change, offset < cursor {
                    cursor += 1
                }
            }
            // A correction can lengthen a word immediately before the
            // boundary. Do not display its unaligned suffix as a new word.
            while cursor > 0, cursor < next.count, next[cursor - 1].isLetter,
                  next[cursor].isLetter, !PrefixStableText.isCJK(next[cursor]) {
                cursor += 1
            }
        }
        var start = min(cursor, next.count)
        while start < next.count, next[start].isWhitespace { start += 1 }
        guard start < next.count else {
            if final, hasOpenRow, rows.count > 1 {
                rows.removeLast() // only the still-editable tail was retracted
                previous = next
                consumed = start
                hasOpenRow = false
            }
            return
        }
        consumed = start

        var output = hasOpenRow ? Array(rows.dropLast()) : rows
        let protectedThrough = Self.completePrefixEnd(next, at: shared)
        let extendsVisibleText = shared == previous.count
        let sentenceEnds = Self.sentenceEnds(in: value,
            stableThrough: final || extendsVisibleText ? next.count : shared)
        for end in sentenceEnds where end > start && end < next.count {
            // A provisional period added inside already visible words should
            // not send those words to a different row on the next repaint.
            guard end >= protectedThrough || previous.isEmpty else { continue }
            let line = String(next[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            append(line, to: &output, consumedThrough: start, protectedThrough: protectedThrough, fits: fits)
            start = end
            while start < next.count, next[start].isWhitespace { start += 1 }
            consumed = start
        }
        if start < next.count {
            append(String(next[start...]), to: &output, consumedThrough: start,
                   protectedThrough: protectedThrough, fits: fits)
        }
        if !output.isEmpty {
            rows = output
            hasOpenRow = true
        }
        previous = next
    }

    /// Prefer a clause break near the edge, then a word break. A single very
    /// wide token can wrap on grapheme boundaries without losing characters.
    private mutating func append(
        _ text: String, to output: inout [String], consumedThrough start: Int,
        protectedThrough: Int, fits: (String) -> Bool
    ) {
        let chars = Array(text)
        var lower = 0
        while lower < chars.count {
            let remainder = String(chars[lower...])
            if fits(remainder) {
                output.append(remainder)
                return
            }
            var low = lower + 1, high = chars.count
            while low < high {
                let mid = low + (high - low + 1) / 2
                if fits(String(chars[lower..<mid])) { low = mid } else { high = mid - 1 }
            }
            let floor = min(low, max(lower + 1, protectedThrough - start))
            let boundary = (floor...low).reversed().first { index in
                index < chars.count && (chars[index].isWhitespace
                    || (PrefixStableText.isCJK(chars[index - 1])
                        && !Self.closingPunctuation.contains(chars[index])))
            } ?? low
            let clause = (max(floor, lower + max(1, (boundary - lower) * 3 / 4))...boundary).reversed()
                .first { ",，、；;：:—".contains(chars[$0 - 1]) }
            let end = clause ?? boundary
            output.append(String(chars[lower..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            lower = end
            while lower < chars.count, chars[lower].isWhitespace { lower += 1 }
            consumed = start + lower
        }
    }

    private static let closingPunctuation = "，。！？；：、）】」』》,.;:?!)]}\u{201D}\u{2019}\""
    private static let titleAbbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "rev.", "st."]

    private static func completePrefixEnd(_ chars: [Character], at end: Int) -> Int {
        guard end > 0, end < chars.count, chars[end].isLetter || chars[end].isNumber,
              chars[end - 1].isLetter || chars[end - 1].isNumber || ".'’".contains(chars[end - 1]),
              !PrefixStableText.isCJK(chars[end]), !PrefixStableText.isCJK(chars[end - 1])
        else { return end }
        return chars[..<end].lastIndex(where: { $0.isWhitespace }) ?? 0
    }

    private static func sentenceEnds(in text: String, stableThrough: Int) -> [Int] {
        guard stableThrough > 0 else { return [] }
        var ends: [Int] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let phrase = text[range]
            guard let last = phrase.lastIndex(where: { !$0.isWhitespace }) else { return }
            let end = text.distance(from: text.startIndex, to: text.index(after: last))
            let suffix = phrase.reversed().first {
                !$0.isWhitespace && !"」』）】》\u{201D}\u{2019}\"')]}".contains($0)
            }
            guard end <= stableThrough, let suffix, ".?!。！？".contains(suffix) else { return }
            if let token = phrase.split(whereSeparator: \.isWhitespace).last,
               titleAbbreviations.contains(token.lowercased()) { return }
            ends.append(end)
        }
        return ends
    }
}
