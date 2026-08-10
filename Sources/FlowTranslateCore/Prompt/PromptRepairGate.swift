import Foundation

/// Safety gate for repairing a *request* before it is compiled into a prompt.
///
/// `TranscriptCorrectionGate` guards live captions and is tuned for them; three
/// of its assumptions are wrong here:
///
/// 1. **Captions are read once, prompts are reviewed.** A repaired request lands
///    back in the input box for the user to see before anything is compiled, so
///    a slightly bolder repair costs a glance, not a wrong caption. The edit
///    budget is 0.5 rather than 0.35 — the repairs that matter most here are
///    large ones, like `sources uploader dot swift` → `Sources/Uploader.swift`.
/// 2. **Captions have no code in them.** A request is full of identifiers,
///    paths and flags, and a repair that "tidies" one has broken the task while
///    reading perfectly. Any code-shaped span in the original must still be
///    present afterwards.
/// 3. **Captions can't invert an instruction.** A request can: turning
///    "don't add dependencies" into "add dependencies" is a silent, total
///    failure, and the caption gate has no check for it because a caption has
///    no one downstream to obey it.
///
/// The direction of the asymmetry is deliberate — looser where the user can
/// see the result, strictly tighter where they cannot.
///
/// Pure value logic — fully unit-testable, no model involved.
public enum PromptRepairGate {

    /// Maximum normalized character edit distance.
    ///
    /// Looser than the caption gate's 0.35 because the repairs worth having
    /// here are large ones on short lines, where a single mangled term is a
    /// big fraction of the characters: `use cooper netties for deploy` →
    /// `Use Kubernetes for deployment` scores 0.379 and the caption gate throws
    /// it away. The extra room is affordable only because the result is shown to
    /// the user before anything is compiled.
    static let editBudget = 0.5

    /// Whether a line is worth spending a generation on.
    ///
    /// Unlike captions, length is not the only signal: a line that is already
    /// nothing but a path or a command has nothing a language model can improve
    /// and everything to lose.
    public static func shouldAttempt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isPureCode(trimmed) else { return false }
        // Any CJK at all means counting characters, not words. Dominance was the
        // wrong threshold and it silently disqualified this app's most common
        // input: "依照claude opus5的官方建議prompt寫法" is 9 CJK characters among
        // 17 Latin ones, so it failed the dominance test, and it contains a
        // single space, so the word-count branch saw two words and refused to
        // repair it. Code-switched text has neither enough CJK to be dominant
        // nor enough spaces to be counted — it fell between the two rules.
        let hasCJK = trimmed.contains { TokenEstimator.isCJK($0) }
        return hasCJK
            ? trimmed.count(where: { !$0.isWhitespace }) >= 6
            : trimmed.split(whereSeparator: \.isWhitespace).count >= 3
    }

    /// A line the user clearly pasted rather than spoke: a path, a command, a
    /// stack frame. Repairing these is all downside.
    ///
    /// Deliberately not `LexicalCompressor.isProtected`, which counts any CJK
    /// token as protected — correct there, since Chinese cannot be pruned, but
    /// here it classified every Chinese sentence as pure code, because Chinese
    /// has no spaces and so arrives as a single "word".
    static func isPureCode(_ text: String) -> Bool {
        if text.hasPrefix("$") || text.hasPrefix("```") { return true }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }
        guard !words.contains(where: { $0.contains { TokenEstimator.isCJK($0) } }) else {
            return false
        }
        let codeLike = words.filter { LexicalCompressor.isProtected($0) }.count
        // Mostly code and short enough to be a fragment rather than a sentence.
        return words.count <= 6 && codeLike * 2 > words.count
    }

    /// Strip the decoration a model adds even when told not to.
    public static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("```") }
            s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let firstLine = s.split(separator: "\n").first {
            s = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["Corrected:", "Correction:", "Output:", "Line:", "Repaired:",
                      "Rewritten:", "修正：", "修正:", "整理後：", "整理後:"]
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

    /// Why a repair was thrown away. Surfaced so a rejection can be explained
    /// instead of silently looking like the model did nothing.
    public enum Rejection: String, Sendable, Equatable {
        case empty
        case unchanged
        case multiline
        case lengthRatio
        case numberChanged
        case codeLost
        case negationFlipped
        case tooDifferent
        case meta
        /// The repair converted Traditional Chinese into Simplified.
        case simplifiedChinese
    }

    /// `nil` when the repair is acceptable, otherwise why it was rejected.
    public static func rejection(original: String, corrected: String) -> Rejection? {
        let orig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corr = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orig.isEmpty, !corr.isEmpty else { return .empty }
        guard corr != orig else { return .unchanged }
        guard !corr.contains("\n") else { return .multiline }
        if readsAsMeta(corr) { return .meta }
        // Qwen is trained mostly on Simplified Chinese and drifts into it on an
        // instruction that only says "keep the same language" — Simplified and
        // Traditional are the same language, so the instruction is obeyed and
        // the output is still wrong. Rejected rather than converted: a
        // Simplified → Traditional mapping is lossy both ways, so a converter
        // would corrupt text that was already right.
        if SimplifiedChineseDetector.introducesSimplified(original: orig, corrected: corr) {
            return .simplifiedChinese
        }

        let ratio = Double(corr.count) / Double(orig.count)
        guard (0.5...2.0).contains(ratio) else { return .lengthRatio }

        guard TranscriptCorrectionGate.digitRuns(orig) == TranscriptCorrectionGate.digitRuns(corr)
        else { return .numberChanged }

        // Every identifier, path and flag in the original must still be there.
        // A repair is allowed to *add* structure a dictation lost, and to fix
        // case and spacing; it is never allowed to lose one that was correct.
        if !keepsIdentifiers(original: orig, corrected: corr) { return .codeLost }

        // The one failure with no upside. A request that forbade something and
        // now permits it has been inverted, and every downstream stage will
        // faithfully carry the inversion through.
        // A-not-A question forms are removed from both sides first. 是不是 /
        // 要不要 / 可不可以 are built out of 不 and forbid nothing, so a sentence
        // that merely stops being a question — the repair's job, when the
        // speaker dictated one — read as an inverted instruction and was thrown
        // away. See `ChineseQuestionForms`.
        guard SymbolCompressor.isNegated(ChineseQuestionForms.stripped(from: orig))
                == SymbolCompressor.isNegated(ChineseQuestionForms.stripped(from: corr))
        else { return .negationFlipped }

        let a = Array(orig.lowercased()), b = Array(corr.lowercased())
        let denom = max(a.count, b.count)
        guard denom > 0 else { return .empty }
        let distance = Double(TranscriptCorrectionGate.levenshtein(a, b)) / Double(denom)
        return distance <= editBudget ? nil : .tooDifferent
    }

    public static func accepts(original: String, corrected: String) -> Bool {
        rejection(original: original, corrected: corrected) == nil
    }

    /// The model answering *about* the task instead of doing it.
    static func readsAsMeta(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let openers = [
            "here is", "here's", "sure,", "certainly", "i have corrected",
            "the corrected", "no changes", "this sentence", "as an ai",
            "以下是", "好的，", "這句話",
        ]
        return openers.contains { lowered.hasPrefix($0) }
    }

    /// Identifiers, paths, flags and versions, normalized for comparison.
    ///
    /// Case- and space-insensitive, because the repairs worth keeping are
    /// exactly the ones that restore case and spacing: `claude opus5` →
    /// `Claude Opus 5` was rejected as "lost identifier `opus5`" when it is the
    /// correct fix. What must never change is *which characters* the identifier
    /// is made of, and that survives this normalization — `maxRetryCount` →
    /// `maxAttempts` is still caught, because the letters differ.
    static func codeTokens(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        for span in LexicalCompressor.codeSpans(in: text) {
            let token = String(text[span]).trimmingCharacters(in: .whitespaces)
            if token.count > 1 { tokens.insert(normalizedIdentifier(token)) }
        }
        return tokens
    }

    /// An identifier reduced to the characters that make it that identifier.
    ///
    /// Deliberately keeps digits and letters and drops everything else, so a
    /// path stays distinguishable from the words around it while case and
    /// separators become free to fix.
    static func normalizedIdentifier(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Whether every identifier in `original` survives in `corrected`.
    ///
    /// Compared as a normalized *string*, not a token set, so a repair that
    /// merely inserts a space inside an identifier-looking run of prose still
    /// finds its characters present.
    static func keepsIdentifiers(original: String, corrected: String) -> Bool {
        let haystack = normalizedIdentifier(corrected)
        return codeTokens(original).allSatisfy { haystack.contains($0) }
    }
}
