import Foundation

/// Strips the artifacts of *speaking* from a dictated request, in English and
/// Chinese, before the request reaches the model.
///
/// This runs only when the text came from a microphone. Typed input has no
/// hesitation sounds, so cleaning it can only do harm — a deliberate "嗯" in a
/// written note, or a fragment inside a pasted code snippet, would be eaten for
/// nothing. See `PromptInputOrigin.needsSpokenCleanup`.
///
/// The filler list is deliberately narrow, for the same reason `BasicTextCleaner`
/// keeps its own list narrow: discourse phrases carry meaning far more often
/// than they look like they do, and deleting them corrupts the request.
/// Anything ambiguous is left for the intent-extraction model, which is the one
/// stage with the context needed to judge it.
///
/// Two categories are therefore **not** handled here on purpose:
///
/// - **Chinese discourse markers** — 就是 / 然後 / 那個 / 反正 are ordinary words
///   ("然後呢？", "就是這個", "那個檔案"). No amount of surrounding-context
///   heuristics makes stripping them safe.
/// - **Chinese reduplication** — 看看, 常常, 研究研究 and 討論討論 are standard
///   morphology, not stutter. Since a repeated-token rule cannot separate those
///   from a genuine "這個這個", the rule simply is not applied to CJK at all.
public struct SpokenNoiseCleaner: Sendable {

    /// Space-delimited English hesitation sounds.
    ///
    /// `mm` and `hm` are **not** here despite being hesitation sounds, because
    /// they are also units: "set the inset to 8 mm" became "set the inset to 8",
    /// deleting the very thing the compressor's `isProtected` guards downstream.
    /// A filler list that can eat a measurement is not worth the two tokens it
    /// saves. `er` is likewise gone — it is a plausible fragment of a mis-split
    /// word, and `erm`/`uhm` cover the actual hesitation.
    public static let englishFillers = [
        "um", "uh", "uhm", "umm", "erm", "hmm", "mhm", "ah",
    ]

    /// Single-character Chinese interjections. Chinese has no word spaces, so
    /// these are matched per character rather than bounded by whitespace.
    /// Every one is a pure interjection — removing it never changes what is
    /// being asked for ("欸你看" → "你看").
    public static let chineseFillerCharacters: Set<Character> = ["嗯", "呃", "唔", "痾", "欸", "唉"]

    public init() {}

    /// Clean `text` if `origin` involved speech; otherwise return it untouched.
    public func cleanup(_ text: String, origin: PromptInputOrigin) -> String {
        guard origin.needsSpokenCleanup else { return text }
        return cleanup(text)
    }

    /// Clean the text, line by line.
    ///
    /// Per line rather than in one pass because two of the three stages are
    /// space-delimited — `removeEnglishFillers` pads with spaces to bound a
    /// match, and `collapseEnglishStutters` splits on spaces and rejoins with
    /// them — so running them over the whole request replaced every newline with
    /// a space. Dictated text has no newlines to lose, which is why it went
    /// unnoticed; a typed request is written one requirement per line, and that
    /// structure is content.
    public func cleanup(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map(cleanupLine)
            .joined(separator: "\n")
    }

    private func cleanupLine(_ line: String) -> String {
        var result = removeEnglishFillers(line)
        result = removeChineseFillers(result)
        result = collapseEnglishStutters(result)
        return tidyWhitespace(result)
    }

    // MARK: - English

    private func removeEnglishFillers(_ text: String) -> String {
        // Pad so a filler at either end is still space-bounded, and loop until
        // stable so adjacent repeats ("um um") are fully removed — replacing in
        // one pass leaves the overlapping space behind.
        var padded = " " + text + " "
        var changed = true
        while changed {
            changed = false
            for filler in Self.englishFillers {
                let next = padded.replacingOccurrences(
                    of: " \(filler) ",
                    with: " ",
                    options: [.caseInsensitive]
                )
                if next != padded {
                    padded = next
                    changed = true
                }
            }
        }
        return padded
    }

    /// "the the file" → "the file".
    ///
    /// Restricted to ASCII-letter tokens so it can never reach Chinese
    /// reduplication: 看看, 常常 and 研究研究 are morphology, not stutter, and a
    /// repeated-token rule has no way to tell them from a genuine "這個這個".
    private func collapseEnglishStutters(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        var result: [Substring] = []
        for token in tokens {
            if let previous = result.last,
               previous.lowercased() == token.lowercased(),
               token.allSatisfy({ $0.isLetter && $0.isASCII }) {
                continue
            }
            result.append(token)
        }
        return result.joined(separator: " ")
    }

    // MARK: - Chinese

    private func removeChineseFillers(_ text: String) -> String {
        guard text.contains(where: { Self.chineseFillerCharacters.contains($0) }) else { return text }

        let stripped = String(text.filter { !Self.chineseFillerCharacters.contains($0) })
        // If the utterance was nothing but interjections there is no request to
        // preserve — hand back the original rather than an empty string.
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return stripped
    }

    // MARK: - Whitespace

    private func tidyWhitespace(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        // Removing a filler can strand a space in front of punctuation, in
        // either half-width or full-width form.
        for mark in [",", ".", "!", "?", ";", ":", "，", "。", "！", "？", "、", "；", "："] {
            result = result.replacingOccurrences(of: " \(mark)", with: mark)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
