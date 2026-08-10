import Foundation

/// Small counting helpers shared by the endpointing, splitting and repair rules.
///
/// They live here because each of them was defined twice, and the two copies
/// were not always the same thing:
///
/// - `contentCharacters` was identical in `Endpointer` and `SentenceSplitter`,
///   which is worse than it sounds rather than better: those two decide "is this
///   enough text to be a sentence?" from opposite ends of the pipeline, and a
///   change to one copy would have silently desynchronised the endpointer's close
///   rule from the splitter's merge rule.
/// - `occurrences(of:in:)` existed twice with the **same name, the same
///   signature and different answers** — `PassageRepairGate`'s counted
///   overlapping matches, `SelfCorrectionCues`' counted non-overlapping ones. On
///   `"aaaa"` searching `"aa"` one said three and the other said two. Whichever
///   was in scope won, and nothing said which you had.
///
/// Only the non-overlapping one survives: rewriting `PassageRepairGate.looped`
/// onto a rolling-hash index removed its last caller, so the ambiguity is gone by
/// deletion rather than by disambiguation. The name still says which it is, so
/// the next caller has to mean it.
public enum TextCounting {

    /// Letters and digits, ignoring punctuation, spaces and symbols.
    ///
    /// The unit both "is this a sentence?" rules count in.
    public static func contentCharacters(_ text: String) -> Int {
        text.count { $0.isLetter || $0.isNumber }
    }

    /// Occurrences of `needle` that do **not** overlap: each match consumes its
    /// own characters.
    ///
    /// What cue counting wants — two adjacent "不對不對" is two corrections, not
    /// three overlapping matches of a cue that only appears twice. Named for the
    /// semantics rather than called `occurrences`, because the other reading is a
    /// legitimate thing to want and the two are not interchangeable.
    public static func nonOverlappingOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }
}
