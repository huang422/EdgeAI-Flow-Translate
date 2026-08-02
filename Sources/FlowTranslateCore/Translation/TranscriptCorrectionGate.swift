import Foundation

/// Safety gate for LLM-based generative error correction (GER) of ASR output.
///
/// GER (HyPoradise, NeurIPS 2023; RobustGER, ICLR 2024) reliably fixes
/// homophones, proper nouns and punctuation — but an unguarded LLM can also
/// paraphrase or hallucinate. This gate accepts a correction only when it is a
/// plausible *repair* of the original:
///
/// - non-empty, single-line, and actually different
/// - length within 0.5×–2× of the original
/// - every digit run preserved (numbers must never change silently)
/// - normalized character edit distance ≤ 0.35
///
/// Pure value logic — fully unit-testable.
public enum TranscriptCorrectionGate {

    /// Whether a finalized sentence is worth sending to the corrector at all.
    ///
    /// The GER literature's standard intake filter is the ASR's own per-token
    /// confidence (Confidence-Guided Error Correction, arXiv 2509.25048), but
    /// FluidAudio hardcodes `TokenTiming.confidence` to 1.0 on the Nemotron
    /// streaming path, so no such signal exists here. Length is the honest
    /// substitute: very short utterances ("Okay.", "Yes.") hold nothing an LLM
    /// can repair while carrying the highest relative hallucination risk.
    public static func shouldAttempt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // The unit differs by script, so the floors aren't comparable: four words
        // is a sentence worth checking, while it takes roughly eight hanzi before
        // a line is more than a pleasantry.
        return isCJKDominant(trimmed)
            ? trimmed.count(where: { !$0.isWhitespace }) >= 8
            : trimmed.split(whereSeparator: \.isWhitespace).count >= 4
    }

    /// Strip the decoration a model adds to a one-line answer even when told not
    /// to: a label, surrounding quotes, or a trailing note on its own line.
    /// Without this the gate would reject perfectly good repairs for cosmetics.
    public static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the first line only — a trailing "(no changes needed)" remark must
        // not cost a valid repair, and the gate rejects multi-line answers.
        if let firstLine = s.split(separator: "\n").first {
            s = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["Corrected:", "Correction:", "Output:", "Line:", "修正：", "修正:"]
        where s.hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("「", "」"), ("\u{201C}", "\u{201D}"),
        ]
        for (open, close) in quotePairs
        where s.count >= 2 && s.first == open && s.last == close {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            break
        }
        return s
    }

    /// Whether `corrected` is an acceptable repair of `original`.
    public static func accepts(original: String, corrected: String) -> Bool {
        let orig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corr = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orig.isEmpty, !corr.isEmpty, corr != orig else { return false }
        guard !corr.contains("\n") else { return false }          // one line in, one line out

        // Length sanity: a repair shouldn't halve or double the sentence.
        let ratio = Double(corr.count) / Double(orig.count)
        guard (0.5...2.0).contains(ratio) else { return false }

        // Numbers are sacred: the multiset of digit runs must survive.
        guard digitRuns(orig) == digitRuns(corr) else { return false }

        // Bounded edit distance, measured in CHARACTERS. ASR's characteristic
        // failure is mis-segmentation ("cooper netties" → "Kubernetes"), and a
        // word-level count scores that as two edits out of six words — it would
        // reject the very repairs this gate exists to let through. (CJK was
        // already character-level; it has no word spaces to count.)
        let a = Array(orig.lowercased()), b = Array(corr.lowercased())
        let dist = levenshtein(a, b)
        let denom = max(a.count, b.count)
        guard denom > 0 else { return false }
        return Double(dist) / Double(denom) <= 0.35
    }

    // MARK: - Internals

    /// Whether CJK characters make up at least half the text — such text has no
    /// spaces, so word-level tokenization would yield one giant token.
    static func isCJKDominant(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return false }
        return scalars.filter(isCJK).count * 2 >= scalars.count
    }

    /// Multiset of digit runs ("v2 costs 300" → ["2", "300"]).
    static func digitRuns(_ text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for ch in text {
            if ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.sorted()
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x9FFF, 0x3400...0x4DBF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
