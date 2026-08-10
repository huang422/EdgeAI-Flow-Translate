import Foundation

/// Display-side stabilizer for live (interim) translations.
///
/// Re-translating a growing sentence rewrites the **head** of the translation on
/// almost every update (target-language word order differs from the source), which
/// makes the second caption the jumpiest element on screen. This implements the
/// display strategy from Google's re-translation research (Arivazhagan et al.,
/// ICASSP 2020): show only the *stable prefix* — the longest common prefix of the
/// two most recent candidates — so the displayed text only ever **extends**,
/// never rewrites.
///
/// Rules:
/// - The first candidate is shown immediately (something beats nothing).
/// - Afterwards the displayed text grows to the stable prefix whenever that
///   prefix extends what is already shown.
/// - A candidate that *conflicts* with the displayed text (the stable prefix no
///   longer covers it) is held back; after `conflictLimit` consecutive conflicts
///   the display resyncs to the latest candidate in one replacement (rendered as
///   a single crossfade by the view layer).
/// - `commit(_:)` installs the accurate finalized translation.
///
/// Pure value type — fully unit-testable, no clocks, no UI.
public struct PrefixStableText: Equatable, Sendable {
    /// The text that should currently be displayed.
    public private(set) var displayed: String = ""

    private var lastCandidate: String = ""
    private var conflicts = 0
    private let conflictLimit: Int

    public init(conflictLimit: Int = 3) {
        self.conflictLimit = max(1, conflictLimit)
    }

    /// Drop all state (new utterance).
    public mutating func reset() {
        displayed = ""
        lastCandidate = ""
        conflicts = 0
    }

    /// Install the accurate finalized translation (always wins).
    @discardableResult
    public mutating func commit(_ final: String) -> String {
        displayed = final
        lastCandidate = final
        conflicts = 0
        return displayed
    }

    /// Feed a new full-translation candidate; returns the text to display.
    @discardableResult
    public mutating func update(candidate: String) -> String {
        let cand = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cand.isEmpty else { return displayed }
        defer { lastCandidate = cand }

        // First candidate of the utterance: show it right away.
        if lastCandidate.isEmpty {
            displayed = cand
            conflicts = 0
            return displayed
        }

        let stable = Self.stablePrefix(lastCandidate, cand)
        if stable.hasPrefix(displayed) {
            // The stable prefix confirms everything shown — extend if it grew.
            if stable.count > displayed.count { displayed = stable }
            conflicts = 0
        } else {
            // The candidate disagrees with what's shown. Hold (freeze) — unless
            // it keeps disagreeing, then resync once to avoid drifting stale.
            conflicts += 1
            if conflicts >= conflictLimit {
                displayed = cand
                conflicts = 0
            }
        }
        return displayed
    }

    // MARK: - Prefix logic

    /// Longest common prefix of two candidates, snapped back to a word boundary
    /// for spaced scripts (never cuts "computer" into "compu"); CJK text snaps
    /// per character (no spaces to align to).
    static func stablePrefix(_ a: String, _ b: String) -> String {
        var prefix = ""
        var ia = a.startIndex, ib = b.startIndex
        while ia < a.endIndex, ib < b.endIndex, a[ia] == b[ib] {
            prefix.append(a[ia])
            ia = a.index(after: ia)
            ib = b.index(after: ib)
        }
        guard !prefix.isEmpty, ib < b.endIndex else { return prefix }

        // Mid-word cut for a spaced script → trim back to the last whitespace
        // (drop the partial word entirely; it isn't stable yet).
        let next = b[ib]
        if let last = prefix.last,
           !last.isWhitespace, !next.isWhitespace,
           !Self.isCJK(last), !Self.isCJK(next) {
            if let ws = prefix.lastIndex(where: { $0.isWhitespace }) {
                prefix = String(prefix[..<ws])
            } else {
                prefix = ""
            }
        }
        return prefix
    }

    /// Whether a character belongs to the CJK blocks (no inter-word spaces).
    ///
    /// Extension A (U+3400–4DBF) is inside the first range; listing it again was
    /// a case the compiler could never reach.
    static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF,      // radicals, punctuation, ideographs, kana, ext. A
             0xAC00...0xD7AF,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFF00...0xFFEF,      // full-width forms
             0x20000...0x2FA1F:    // CJK extensions B+
            return true
        default:
            return false
        }
    }
}
