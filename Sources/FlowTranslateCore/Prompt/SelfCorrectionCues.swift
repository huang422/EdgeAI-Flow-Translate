import Foundation

/// The words people say when they change their mind mid-dictation.
///
/// Used to decide how much a passage repair is allowed to **delete**. Merging a
/// self-correction — "訂在週二下午兩點，啊不對，改成週三早上十點" coming back as
/// Wednesday only — is the one reason a tidy pass may remove something the
/// speaker said. A passage with no cue in it has asked for no such thing, so it
/// licenses no deletion, and `PassageRepairGate` tightens to something close to
/// its per-sentence sibling.
///
/// Detection is deliberately generous. A false positive loosens the deletion
/// budget slightly on a passage that was not self-corrected; a false negative
/// blocks a merge the user actually asked for. The first is recoverable, the
/// second reads as the feature not working.
public enum SelfCorrectionCues {

    /// English cues, matched on word boundaries so `rather` does not fire inside
    /// `gather` and `sorry` does not fire inside a surname.
    /// Compound forms first, so the negation-carrying ones are matched and
    /// consumed before the bare cue inside them. "actually no" has to be one cue
    /// rather than `actually` plus a stray `no`, or `stripped(from:)` leaves the
    /// negation marker behind and the gate reads a discarded correction as a
    /// prohibition the repair dropped.
    ///
    /// Both `count(in:)` and `stripped(from:)` rely on this order **and** on
    /// consuming what they match; either one alone is not enough.
    public static let english = [
        "no actually", "actually no", "no wait", "wait no", "sorry no",
        "let me rephrase", "rather than that", "scratch that", "strike that",
        "or rather", "make that", "correction",
        "i meant", "i mean", "actually", "sorry",
    ]

    /// Chinese cues, matched as substrings — Chinese has no word boundaries to
    /// respect.
    ///
    /// Every entry is at least two characters. A single character would fire
    /// inside ordinary words, and the shortest plausible cue (`不對`) is already
    /// a substring of the far more common `是不是不對` shapes, so nothing shorter
    /// is safe. `不是` is deliberately absent for that reason: it is a plain
    /// negation ("這不是重點") far more often than a correction.
    public static let chinese = [
        "不對", "我是說", "我的意思是", "更正", "應該是說", "講錯", "說錯",
        "改成", "等一下", "重講", "抱歉",
    ]

    /// How many self-correction cues `text` contains.
    ///
    /// Counted rather than tested, because the budget scales: one cue buys one
    /// merge, three buy three. A passage that corrects itself repeatedly is
    /// exactly the one that legitimately shrinks the most.
    /// Counted by **consuming** each match, longest cue first.
    ///
    /// Counting each cue independently double-counted every compound: "actually
    /// no" scored once as the phrase and once again for the bare `actually`
    /// inside it, so one correction bought two merges' worth of deletion — 50
    /// tokens instead of 25, `dropAllowance` 2 instead of 1, and twice the
    /// edit-distance bonus. `PassageRepairGate` then accepted a repair that had
    /// deleted about twice what the speaker licensed. The doc on `english` claimed
    /// longest-first ordering prevented this; it does, but only for
    /// `stripped(from:)`, which consumes its matches. This one has to as well.
    public static func count(in text: String) -> Int {
        let lowered = text.lowercased()
        var total = 0

        // Word-bounded for Latin. Splitting on non-alphanumerics rather than
        // whitespace so punctuation around a cue does not hide it: "…two, sorry,
        // three" must still count.
        //
        // Optional slots rather than a plain array: a matched phrase blanks the
        // tokens it used, so the bare cue inside it can no longer match them.
        var words: [String?] = lowered
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        for cue in english {
            let parts = cue.split(separator: " ").map(String.init)
            total += consumeOccurrences(of: parts, in: &words)
        }
        // Chinese has no token boundaries, so the same job is done by removing
        // the matched substring from a working copy.
        var remaining = text
        for cue in chinese {
            let hits = TextCounting.nonOverlappingOccurrences(of: cue, in: remaining)
            guard hits > 0 else { continue }
            total += hits
            remaining = remaining.replacingOccurrences(of: cue, with: " ")
        }
        return total
    }

    /// How many times `phrase` appears in `words`, blanking each match so it
    /// cannot be counted again by a shorter cue.
    static func consumeOccurrences(of phrase: [String], in words: inout [String?]) -> Int {
        guard !phrase.isEmpty, words.count >= phrase.count else { return 0 }
        var total = 0
        for start in 0...(words.count - phrase.count) {
            let window = words[start..<(start + phrase.count)]
            guard window.elementsEqual(phrase, by: { $0 == $1 }) else { continue }
            total += 1
            for index in start..<(start + phrase.count) { words[index] = nil }
        }
        return total
    }

    /// `text` with the cue words removed.
    ///
    /// Needed because several cues *contain a negation marker* — "actually no",
    /// "no wait", "不對" — and the passage gate's inversion check would otherwise
    /// read the discarded correction marker as a prohibition the repair had
    /// dropped. Merging the correction removes the marker by design, so every
    /// successful merge would have been rejected as an inverted meaning.
    public static func stripped(from text: String) -> String {
        var result = text
        for cue in chinese {
            result = result.replacingOccurrences(of: cue, with: " ")
        }
        for cue in english {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: cue))\\b",
                with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

}
