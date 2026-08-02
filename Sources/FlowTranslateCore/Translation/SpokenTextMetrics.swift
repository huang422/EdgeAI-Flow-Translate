import Foundation

/// Length estimates for spoken lines, shared by every prompt that needs a decode
/// cap. A cap keeps one runaway generation from stalling the queue behind it.
public enum SpokenTextMetrics {

    /// Rough "word" count for a subtitle line.
    ///
    /// Whitespace alone fails for unspaced scripts — a whole Chinese or Japanese
    /// line counts as ONE word, which pinned the cap to its floor and truncated
    /// long lines — so characters/3 is taken as a word-equivalent proxy and the
    /// larger of the two wins.
    public static func units(_ text: String) -> Int {
        let spaced = text.split { $0 == " " || $0 == "\n" }.count
        let byChars = text.count / 3            // CJK ≈ 1 word per ~1–3 chars
        return max(1, max(spaced, byChars))
    }
}
