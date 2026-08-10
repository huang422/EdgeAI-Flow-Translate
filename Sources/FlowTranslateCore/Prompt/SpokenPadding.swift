import Foundation

/// How much of a passage is verbal padding — the words people say to keep
/// talking rather than to mean something.
///
/// Exists to size a deletion budget. `PassageRepairGate` has to answer "may this
/// repair delete this much?", and until now the only thing that bought deletion
/// room was a self-correction cue. That made Tidy structurally unable to do the
/// thing its name promises: spoken language runs 15–30% padding, removing it
/// blew the budget, the gate rejected the repair, and the fallback handed back
/// the original — so the output read exactly as dictated and the pass looked like
/// it had done nothing.
///
/// Measured per passage rather than assumed, so the budget follows the input: a
/// clean, prepared sentence licenses almost no deletion (the gate stays as strict
/// as it was), while a rambling one licenses removing what is actually in it.
///
/// Deliberately **not** a cleaner. Deleting these words mechanically would strip
/// "like" from "make it work like the uploader does" and "其實" from "其實不是這
/// 樣" — both meaning-bearing. Counting them to set a budget carries no such risk:
/// a wrong count moves an allowance a few tokens, and the model still decides
/// what to remove.
public enum SpokenPadding {

    /// English discourse markers and hedges, longest first so a phrase is
    /// counted as one item rather than as its parts.
    public static let englishMarkers = [
        "you know what i mean", "if that makes sense", "or something like that",
        "i guess you could say", "what i'm trying to say is", "at the end of the day",
        "you know", "i mean", "kind of", "sort of", "i think",
        "let me see", "let's see", "and stuff", "and things",
        "basically", "actually", "literally", "obviously", "essentially",
        "anyway", "so yeah", "right",
    ]

    /// Chinese discourse markers.
    ///
    /// Every entry is at least two characters, and the one-character particles
    /// (吧 / 啦 / 欸) are absent: they attach to ordinary sentences far more often
    /// than they pad one, and this only needs to be right on average.
    public static let chineseMarkers = [
        "你知道嗎", "我的意思是說", "怎麼講", "怎麼說",
        "就是說", "然後就是", "基本上", "反正就是",
        "就是", "然後", "反正", "其實", "對啊", "是這樣子",
        // 那個 / 這個 are deliberately absent. They are the most common Chinese
        // hesitation words *and* ordinary demonstratives — "這個檔案" is "this
        // file" — and nothing cheap tells the two apart. Counting them inflates
        // the deletion budget for text that was never padded, which is the one
        // direction this must not err in; "那個那個" is still caught as a
        // repetition.
    ]

    /// Estimated tokens of padding in `text`.
    ///
    /// Counts markers plus immediate repetitions ("然後然後", "the the"), which is
    /// the other half of what a listener hears as padding and what a cleaner
    /// cannot safely remove either.
    public static func estimatedTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return markerTokens(in: text) + repetitionTokens(in: text)
    }

    static func markerTokens(in text: String) -> Int {
        var remaining = text.lowercased()
        var total = 0
        // Longest first, and each match is consumed, so "you know what i mean"
        // is one marker rather than also counting the "you know" inside it.
        for marker in englishMarkers.sorted(by: { $0.count > $1.count }) {
            while let found = remaining.range(
                of: "\\b\(NSRegularExpression.escapedPattern(for: marker))\\b",
                options: [.regularExpression]
            ) {
                total += TokenEstimator.estimate(marker)
                remaining.replaceSubrange(found, with: " ")
            }
        }
        for marker in chineseMarkers.sorted(by: { $0.count > $1.count }) {
            while let found = remaining.range(of: marker) {
                total += TokenEstimator.estimate(marker)
                remaining.replaceSubrange(found, with: " ")
            }
        }
        return total
    }

    /// Tokens spent on saying the same thing twice in a row.
    static func repetitionTokens(in text: String) -> Int {
        var total = 0

        // Latin: adjacent identical words.
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        for index in 1..<max(1, words.count)
        where words[index] == words[index - 1] && words[index].count >= 2 {
            total += TokenEstimator.estimate(words[index])
        }

        // CJK: an adjacent repeated two-character run ("然後然後"). Single
        // characters are excluded — 看看 / 想想 are ordinary reduplication and
        // mean something.
        let characters = Array(text.filter { !$0.isWhitespace })
        guard characters.count >= 4 else { return total }
        var index = 0
        while index + 3 < characters.count {
            let first = String(characters[index...(index + 1)])
            let second = String(characters[(index + 2)...(index + 3)])
            if first == second, first.allSatisfy(TokenEstimator.isCJK) {
                total += TokenEstimator.estimate(first)
                index += 4
            } else {
                index += 1
            }
        }
        return total
    }
}
