import Foundation

/// Basic text cleanup: removes common spoken filler words and collapses
/// repeated whitespace (FR-006). Applies only to finalized sentences; the
/// platform layer may swap in a richer ITN implementation.
///
/// The default filler list is deliberately restricted to UNAMBIGUOUS
/// hesitation sounds. Multi-word discourse phrases ("you know", "i mean",
/// "kind of", "sort of") are NOT removed: they routinely carry meaning
/// ("What kind of car…", "Do you know him") and deleting them corrupted
/// transcripts — FR-006 asks for fluency, never for changed meaning.
public struct BasicTextCleaner: TextCleaning {
    private let fillers: [String]

    public init(fillers: [String] = ["um", "uh", "uhm", "erm", "hmm"]) {
        self.fillers = fillers
    }

    public func cleanup(_ text: String) -> String {
        var result = " " + text + " "

        // Remove fillers bounded by spaces; loop until stable so adjacent
        // duplicates ("um um") are fully removed (replacing leaves overlaps).
        var changed = true
        while changed {
            changed = false
            for filler in fillers {
                let pattern = " \(filler) "
                let next = result.replacingOccurrences(
                    of: pattern,
                    with: " ",
                    options: [.caseInsensitive]
                )
                if next != result {
                    result = next
                    changed = true
                }
            }
        }

        // Collapse repeated whitespace.
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        // Drop spaces that ended up before punctuation.
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
