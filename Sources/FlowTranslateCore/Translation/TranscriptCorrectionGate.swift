import Foundation

/// Safety gate for LLM-based generative error correction (GER) of ASR output.
///
/// GER (HyPoradise, NeurIPS 2023; RobustGER, ICLR 2024) reliably fixes
/// homophones, proper nouns and punctuation — but an unguarded LLM can also
/// paraphrase or hallucinate. This gate accepts a correction only when it is a
/// plausible *repair* of the original:
///
/// - non-empty, single-line, and actually different
/// - no Simplified characters the original did not already have
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

        // The repair must not change the script.
        //
        // This gate guarded numbers, length and edit distance but not this, while
        // both dictation gates have checked it from the start — and the model is
        // the same Qwen, which is trained predominantly on Simplified and treats
        // "keep the same language" as satisfied by it. So a Chinese meeting with
        // AI transcript correction on could have its **recorded** transcript
        // quietly converted, sentence by sentence, and the edit distance of a
        // conversion sits comfortably under the 0.35 budget. The transcript feeds
        // the summary and every export, so nothing downstream would have caught
        // it either.
        //
        // Rejected rather than converted back, for the reason
        // `SimplifiedChineseDetector` documents: the mapping is lossy both ways,
        // and keeping an unrepaired sentence beats rewriting a correct one.
        guard !SimplifiedChineseDetector.introducesSimplified(original: orig, corrected: corr)
        else { return false }

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

    /// Multiset of **positional** digit runs ("v2 costs 300" → ["2", "300"]).
    ///
    /// Digits only, and that restriction is the whole point. `Character.isNumber`
    /// is true for 一 二 三 十 百 千 萬 — they carry a numeric value in Unicode —
    /// so every ordinary Chinese sentence yields "digit runs": 幫我看**一**下 is
    /// `["一"]`, 第**一**個 is `["一"]`, **十**分重要 is `["十"]`. Counting those
    /// rejects almost every Chinese repair under the "numbers must not change"
    /// rule, which is Tidy appearing to do nothing on Chinese while working on
    /// English.
    ///
    /// Chinese numerals are words: they keep the protection every other word has
    /// — the edit-distance budget and the content rules — and lose only a rule
    /// never written for them. 三十秒 rewritten as "30 秒" is still rejected, since
    /// the runs differ (`[]` against `["30"]`).
    ///
    /// **Full-width digits fold to ASCII rather than being skipped.** Qwen emits
    /// ０-９ in Chinese routinely, so an `isASCII` test gives 價格３００元 no runs at
    /// all — and a repair returning 價格５００元 none either, matching, and putting
    /// an invented number into the transcript, the summary and every export.
    /// Folding also makes ３００ and 300 compare equal, which is a width
    /// normalization rather than a changed number.
    static func digitRuns(_ text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for ch in text {
            if let digit = asciiDigit(ch) {
                current.append(digit)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.sorted()
    }

    /// `corrected`'s digit runs, minus the ones the speaker said in Chinese
    /// numerals — those are a **normalization**, not an invented number.
    ///
    /// A speaker says 三十秒 and the repair writes "30 秒" — exactly the tidying
    /// this pass exists for. Without the subtraction it costs the whole passage:
    /// the original has no digit runs (`digitRuns` counts positional digits only,
    /// so 幫我看**一**下 is not read as containing a number), the repair has one,
    /// and the gate calls it invented.
    ///
    /// Only the **invented** side is relaxed. Chinese numerals stay out of the
    /// "numbers were dropped" accounting: that is the check whose false positives
    /// made Chinese repairs impossible in the first place, and a run removed here
    /// matches nothing in the original, so it cannot mask a real drop either.
    ///
    /// An actual invention is still caught — 三十 → "50" is not a value the
    /// original names, so it is rejected exactly as before.
    public static func digitsNotNamedInChinese(of corrected: String, saidIn original: String) -> [String] {
        let runs = digitRuns(corrected)
        guard !runs.isEmpty else { return runs }
        let spokenValues = ChineseNumerals.values(in: original)
        guard !spokenValues.isEmpty else { return runs }
        return runs.filter { run in
            guard let value = Int(run) else { return true }
            return !spokenValues.contains(value)
        }
    }

    /// `ch` as an ASCII digit, for the ASCII and full-width forms; nil otherwise.
    private static func asciiDigit(_ ch: Character) -> Character? {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1
        else { return nil }
        switch scalar.value {
        case 0x30...0x39: return ch                                  // 0-9
        case 0xFF10...0xFF19:                                        // ０-９
            return Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)
        default: return nil
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
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

}
