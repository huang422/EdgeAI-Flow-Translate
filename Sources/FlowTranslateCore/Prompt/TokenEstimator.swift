import Foundation

/// Offline estimate of what a string costs a modern BPE tokenizer.
///
/// **Which tokenizer.** Anthropic does not publish Claude's, and the only exact
/// answer — `POST /v1/messages/count_tokens` — is a network call this app
/// deliberately cannot make. OpenAI's `tiktoken` is not a substitute either: it
/// undercounts Claude by roughly 15–20% on prose and considerably more on code
/// and CJK. So the constants below are calibrated against the **only tokenizer
/// this machine can actually consult**: the Qwen3 BPE that ships beside the
/// local weights. That is also the counter `TokenMeter` reports as exact, so the
/// estimate and the measurement now describe the same thing instead of drifting
/// against each other. Claude's own count will differ; every number reaching the
/// UI is labelled `≈` for exactly that reason, and `TokenCountSource` says which
/// counter produced it.
///
/// **How.** Segment the text into character classes and apply a per-class
/// chars-per-token ratio. That tracks BPE far better than one global constant,
/// because the classes genuinely differ: Latin prose merges whole words, while
/// CJK sits near one token per character and a digit run is split one token per
/// digit. A single ratio would be wrong by 4× on mixed Chinese/English input,
/// which is exactly the input this app expects.
///
/// What a user actually needs is the *ratio* between two versions of one prompt,
/// and that ratio stays honest even when the absolute count drifts.
public enum TokenEstimator {

    // MARK: - Calibration
    //
    // Kept together and public so the tests and the in-app calibration probe can
    // both read them: the probe prints each measured ratio next to the constant
    // it is meant to calibrate, which is only useful if it can see the constant.
    // If these are ever re-calibrated against real tokenizer output, this is the
    // only block that changes.
    //
    // Set by least-squares fit against `tokenizer.json` from
    // Qwen3-4B-Instruct-2507 over a corpus of rendered prompts, rules files and
    // raw requests in all three scripts this app sees. The previous values were
    // guesses in the style of published "~4 characters per token" advice and ran
    // +14% aggregate / +26% worst-case against the real tokenizer; these run
    // +1% / +21%. Re-derive them with the calibration probe in Settings, which
    // prints each measured ratio next to the constant it calibrates.

    /// Latin script: BPE merges whole words and common suffixes, so ordinary
    /// prose reaches ~5 characters per token and identifier-dense text ~3.5.
    public static let latinCharsPerToken = 4.3
    /// Han / Kana / Hangul. Common two-character words merge into one token,
    /// which is why this sits above 1 rather than at it.
    public static let cjkCharsPerToken = 1.25
    /// Digit runs are split one token per digit — the densest class there is,
    /// denser even than CJK. Measured at exactly 1.00 on a pure digit probe.
    public static let digitCharsPerToken = 1.0
    /// Brackets, operators, path separators. Adjacent runs (`</task>`, `{a:[b]}`)
    /// merge, so this stays well above the digit ratio.
    public static let symbolCharsPerToken = 2.2
    /// Punctuation usually rides along with a neighbouring token.
    public static let punctuationTokenCost = 0.3
    /// A newline is reliably its own token.
    public static let newlineTokenCost = 1.0

    // MARK: - Estimating

    /// Approximate token count for `text`. Returns 0 for blank input.
    public static func estimate(_ text: String) -> Int {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }

        var latin = 0.0, cjk = 0.0, digit = 0.0, symbol = 0.0
        var punctuation = 0.0, newlines = 0.0

        for character in text {
            if character.isNewline {
                newlines += 1
            } else if character.isWhitespace {
                // A leading space is folded into the token that follows it, so
                // charging for it separately would double-count.
                continue
            } else if isCJK(character) {
                // Must precede `isLetter`: Han characters are letters too.
                cjk += 1
            } else if character.isNumber {
                digit += 1
            } else if character.isLetter {
                latin += 1
            } else if character.isPunctuation {
                punctuation += 1
            } else {
                symbol += 1
            }
        }

        let total =
            latin / latinCharsPerToken
            + cjk / cjkCharsPerToken
            + digit / digitCharsPerToken
            + symbol / symbolCharsPerToken
            + punctuation * punctuationTokenCost
            + newlines * newlineTokenCost

        return max(1, Int(total.rounded()))
    }

    /// Approximate token count for a list rendered one item per line.
    public static func estimate(_ lines: [String]) -> Int {
        estimate(lines.joined(separator: "\n"))
    }

    // MARK: - Script detection

    /// Whether CJK characters make up at least half of the non-space text.
    ///
    /// Used to pick a language for the compiled prompt and to decide whether the
    /// spoken-noise cleaner should apply its Chinese or English filler list.
    public static func isCJKDominant(_ text: String) -> Bool {
        let significant = text.filter { !$0.isWhitespace }
        guard !significant.isEmpty else { return false }
        return significant.count(where: isCJK) * 2 >= significant.count
    }

    /// Whether the text mixes CJK and Latin letters — the code-switching case
    /// ("幫我 refactor 這個 function") that this app treats as normal input.
    public static func isMixedScript(_ text: String) -> Bool {
        var sawCJK = false, sawLatin = false
        for character in text {
            if isCJK(character) {
                sawCJK = true
            } else if character.isLetter {
                sawLatin = true
            }
            if sawCJK && sawLatin { return true }
        }
        return false
    }

    /// Whether a character is priced at the CJK ratio.
    ///
    /// The first range deliberately spans CJK punctuation (U+3000–303F) and the
    /// full-width forms as well as the ideographs, so `。`、`，` are charged at
    /// `cjkCharsPerToken` rather than `punctuationTokenCost`. That is not an
    /// oversight: `cjkCharsPerToken` was calibrated against the real tokenizer on
    /// ordinary Chinese text, punctuation included, so pulling those characters
    /// into the cheaper class would make the ratio wrong by exactly as much as it
    /// "fixed". Re-run the probe in Settings before changing either.
    ///
    /// Extension A (U+3400–4DBF) is *not* listed separately — it is inside the
    /// first range, and having it as its own alternative was a dead branch that
    /// made the set look wider than it is.
    public static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF,      // radicals, CJK punctuation, kana, ideographs, ext. A
             0xAC00...0xD7AF,      // Hangul syllables
             0xF900...0xFAFF,      // compatibility ideographs
             0xFF00...0xFFEF,      // full-width forms
             0x20000...0x2FA1F:    // extensions B–F
            return true
        default:
            return false
        }
    }
}

/// A before/after token measurement, for showing the user what compression
/// actually bought them.
public struct TokenComparison: Sendable, Equatable {
    public let before: Int
    public let after: Int
    /// How the two numbers were obtained. Both ends always share one method —
    /// a saving computed from two different counters would be partly an
    /// artifact of the method change.
    public let source: TokenCountSource

    public init(before: Int, after: Int, source: TokenCountSource = .heuristic) {
        self.before = before
        self.after = after
        self.source = source
    }

    public init(before: String, after: String) {
        self.init(before: TokenEstimator.estimate(before), after: TokenEstimator.estimate(after))
    }

    public var saved: Int { before - after }

    /// Percentage saved, negative when the "optimized" text grew. Zero when
    /// there was nothing to measure.
    public var savedPercent: Int {
        guard before > 0 else { return 0 }
        return Int((Double(saved) / Double(before) * 100).rounded())
    }

    /// `820 → 310 (−62%)`, ready to show.
    ///
    /// The `≈` appears only on heuristic counts. A real tokenizer's number is
    /// exact for the model it came from, and hedging it would understate what
    /// is actually known.
    public var summary: String {
        guard before > 0 else { return source.isExact ? "0" : "≈0" }
        let mark = source.isExact ? "" : "≈"
        let sign = savedPercent >= 0 ? "−" : "+"
        return "\(mark)\(before) → \(mark)\(after) (\(sign)\(abs(savedPercent))%)"
    }
}
