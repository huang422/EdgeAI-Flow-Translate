import Foundation

/// Basic text cleanup: removes common spoken filler words and collapses
/// repeated whitespace (FR-006). Applies only to finalized sentences; the
/// platform layer may swap in a richer ITN implementation.
public struct BasicTextCleaner: TextCleaning {
    private let fillers: [String]

    public init(fillers: [String] = ["um", "uh", "erm", "hmm", "you know", "i mean", "kind of", "sort of"]) {
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
