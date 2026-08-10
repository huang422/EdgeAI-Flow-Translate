import Foundation

/// Safety gate for repairing a whole dictated passage in one pass.
///
/// `PromptRepairGate` guards one sentence at a time and cannot be reused here,
/// because the two are protecting against opposite things. A per-sentence repair
/// is only ever allowed to *preserve*: every number equal, every identifier
/// still present, one line in and one line out. A passage repair is allowed to
/// **delete**, because merging a self-correction is the whole point — "把會議訂在
/// 週二下午兩點，啊不對，改成週三早上十點" has to come back as Wednesday only, and
/// that drops a weekday, two times and a third of the characters.
///
/// So the rules invert. Instead of "everything in the input must survive", the
/// binding rule is **nothing may appear that was not in the input**: no invented
/// numbers, no invented identifiers, no added lines. Deletion is then permitted,
/// but bounded — a merge drops one date, not five.
///
/// Pure value logic — fully unit-testable, no model involved.
public enum PassageRepairGate {

    /// Why a passage repair was thrown away.
    public enum Rejection: String, Sendable, Equatable {
        case empty
        case unchanged
        /// The model wrote *about* the passage instead of returning it.
        case meta
        /// The repair converted Traditional Chinese into Simplified.
        case simplifiedChinese
        case lengthRatio
        /// A number appears that was never dictated.
        case numberInvented
        /// Too many dictated numbers vanished to be self-correction.
        case numbersDropped
        /// An identifier appears that was never dictated.
        case identifierInvented
        /// Too many dictated identifiers vanished.
        case identifiersDropped
        /// The passage forbade something and no longer does.
        case negationLost
        /// The model added lines — an explanation, or a list it expanded.
        case contentAdded
        /// The model fell into a repetition loop.
        case looped
        /// Generation stopped at the token cap, so the tail is missing.
        ///
        /// Detected from the token counter rather than the text: a passage cut a
        /// third short can still pass a length floor, and there is nothing in the
        /// output itself that says it was cut.
        case truncated
        case tooDifferent
    }

    /// How much deletion this passage licenses.
    ///
    /// The idea the rest of the gate rests on: **deletion has to be earned.**
    /// Merging a self-correction is the one reason a repair may delete, so a
    /// passage that contains no self-correction has no licence to lose anything,
    /// and the gate collapses to something very close to the per-sentence rules.
    /// Without this, "may drop up to two numbers" is permission the model can use
    /// on any passage, for any reason, including summarizing.
    ///
    /// The honest cost: a self-correction with no cue word — "週二兩點 週三十點",
    /// just restated — is blocked. That is deliberate. A cue-less correction is
    /// genuinely indistinguishable from content loss, and a gate that cannot tell
    /// them apart must not guess.
    public struct DeletionBudget: Sendable, Equatable {
        public let cues: Int
        /// How many estimated tokens may disappear.
        public let deletionAllowance: Int
        /// How many distinct numbers or identifiers may disappear.
        public let dropAllowance: Int
        /// Padding measured in the original, as a share of it.
        ///
        /// Carried rather than recomputed: the edit-distance rule needs the same
        /// number the deletion allowance was built from, and measuring twice
        /// walked the passage with forty regexes for a second time — and let the
        /// two rules disagree if a caller passed a budget measured on other text.
        public let paddingShare: Double

        /// Measured in **tokens removed**, not as a length ratio.
        ///
        /// A ratio is the wrong shape, and the tests said so immediately: one
        /// merge is most of a short passage and a rounding error in a long one.
        /// "meet Tuesday at 2, actually no, Wednesday at 10" → "Let's meet
        /// Wednesday at 10." is a legitimate merge at 0.41 of the original, while
        /// the same 0.41 on a two-minute dictation is half the transcript gone.
        /// No single ratio can accept the first and reject the second.
        ///
        /// An absolute allowance can. One abandoned clause is about 25 tokens in
        /// either script — which is why this counts tokens rather than characters,
        /// since a Chinese clause is a third of the characters and the same
        /// amount of meaning. The proportional base on top covers the false
        /// starts and repetitions the spoken-noise cleaner did not catch.
        public static func measured(in text: String) -> DeletionBudget {
            let cues = min(SelfCorrectionCues.count(in: text), 4)
            let size = TokenEstimator.estimate(text)
            // Padding is licensed because the mode promises to remove it.
            //
            // Only cues bought deletion room before, and that made Tidy unable to
            // do what it is named for: spoken language runs 15–30% filler, so
            // removing it blew a budget sized for punctuation, the gate rejected
            // the repair, and the fallback returned the original — the output
            // read exactly as dictated. The allowance is measured from *this*
            // passage, so a prepared sentence still licenses almost nothing.
            //
            // 1.5× the measured padding, because removing a marker takes the
            // scaffolding around it too: "然後就是說我們要…" loses the comma and
            // the connective that only existed to carry it.
            let padding = SpokenPadding.estimatedTokens(in: text)
            return DeletionBudget(
                cues: cues,
                deletionAllowance: Int(Double(size) * baseDeletionFraction)
                    + cues * tokensPerMerge
                    + Int(Double(padding) * paddingRemovalFactor),
                dropAllowance: min(cues, 2),
                paddingShare: size > 0 ? min(1, Double(padding) / Double(size)) : 0
            )
        }
    }

    /// What a repair may remove with no self-correction to justify it: false
    /// starts and repetitions the cleaner missed. Small, because with no cue the
    /// gate is meant to sit close to its per-sentence sibling.
    static let baseDeletionFraction = 0.08

    /// One abandoned clause, in estimated tokens.
    static let tokensPerMerge = 25

    /// How many tokens of deletion each token of measured padding buys.
    ///
    /// Above 1 because padding does not sit alone: the connective and the comma
    /// that existed only to carry it go with it. Below 2 so a passage cannot be
    /// halved on the strength of a few markers.
    static let paddingRemovalFactor = 1.5

    /// The extra normalized edit distance a heavily padded passage may show.
    ///
    /// Deletion spread across a passage moves edit distance as much as any
    /// rewrite does, so licensing the deletion without licensing the distance
    /// would reject the repair on the second rule after passing the first.
    static let maxPaddingEditBonus = 0.2

    // MARK: - Thresholds

    /// The ceiling on growth. The floor is per-passage — see `DeletionBudget`.
    ///
    /// Tight, and much tighter than the per-sentence gate's 2.0, because tidying
    /// can only *add* punctuation, capitalization and spaces. 20% covers a
    /// Chinese passage acquiring a full set of 。and ，, and nothing else
    /// legitimate reaches it.
    ///
    /// This is also the only rule that catches **invented prose**. A whole-passage
    /// edit distance cannot: one hallucinated sentence inside two thousand
    /// characters moves the normalized distance by about 5%, an order of
    /// magnitude below any threshold that would not also reject real repairs. The
    /// subset rules below catch invented numbers and identifiers; a fabricated
    /// clause carrying neither is caught here or not at all.
    static let lengthCeiling = 1.2

    /// The drift budget with nothing to justify drift. Same value as the
    /// per-sentence gate: the unit differs but the question — "is this still the
    /// same text?" — does not.
    ///
    /// Cues buy edit room the same way they buy deletion room, and for the same
    /// reason: a merge on a short passage *is* a large edit. "use uploadChunk for
    /// this, no wait, use uploadBlock" → "Use uploadBlock for this." is a correct
    /// merge at a normalized distance of 0.55, and a flat 0.5 rejects it.
    static let editBudget = 0.5
    static let editBudgetPerCue = 0.12
    static let maxCueEditBonus = 0.3

    /// Above this the edit-distance check is skipped rather than run.
    ///
    /// Levenshtein is O(n·m); at 6,000 characters that is 36M cell operations,
    /// which is the point where a safety check starts costing more than the
    /// generation it is checking. The subset rules above it do not have this
    /// problem and still hold, so skipping costs the drift check alone.
    static let maxDistanceComparison = 6_000

    // MARK: - Sanitizing

    /// Strip the decoration a model adds, **keeping every line**.
    ///
    /// The one place this must not follow `PromptRepairGate.sanitize`, which
    /// takes the first line only — correct for a one-line answer, and here it
    /// would silently truncate a five-line dictation to its first sentence.
    public static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // A fenced block, with or without a language tag on the opening fence.
        if text.hasPrefix("```") {
            text = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("```") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // A label on the first line only. Later lines are content: a dictated
        // list can legitimately begin a line with "Output:".
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first {
            lines[0] = strippingLabel(from: first)
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // A quote pair wrapping the whole passage, not one line of it.
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("「", "」"), ("\u{201C}", "\u{201D}"),
        ]
        for (open, close) in quotePairs
        where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }

    static let labels = [
        "Corrected:", "Correction:", "Output:", "Line:", "Repaired:", "Rewritten:",
        "Text:", "Transcript:", "修正：", "修正:", "整理後：", "整理後:", "輸出：", "輸出:",
    ]

    static func strippingLabel(from line: String) -> String {
        for label in labels where line.hasPrefix(label) {
            return String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    // MARK: - Acceptance

    /// `nil` when the repair is acceptable, otherwise why it was rejected.
    public static func rejection(
        original: String, corrected: String,
        budget: DeletionBudget? = nil
    ) -> Rejection? {
        let budget = budget ?? DeletionBudget.measured(in: original)
        let orig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corr = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orig.isEmpty, !corr.isEmpty else { return .empty }
        guard corr != orig else { return .unchanged }
        if PromptRepairGate.readsAsMeta(corr) { return .meta }
        if SimplifiedChineseDetector.introducesSimplified(original: orig, corrected: corr) {
            return .simplifiedChinese
        }

        // Lines may merge; they may never multiply. A model that returns more
        // lines than it was given has appended something — an explanation, a
        // restatement, or a list it decided to expand.
        if contentLineCount(corr) > contentLineCount(orig) { return .contentAdded }

        guard Double(corr.count) / Double(orig.count) <= lengthCeiling else {
            return .lengthRatio
        }
        let removed = TokenEstimator.estimate(orig) - TokenEstimator.estimate(corr)
        guard removed <= budget.deletionAllowance else { return .lengthRatio }

        if looped(corr, original: orig) { return .looped }

        if let rejection = subsetRejection(
            original: TranscriptCorrectionGate.digitRuns(orig),
            corrected: TranscriptCorrectionGate.digitsNotNamedInChinese(of: corr, saidIn: orig),
            allowance: budget.dropAllowance,
            invented: .numberInvented, dropped: .numbersDropped
        ) { return rejection }

        if let rejection = subsetRejection(
            original: Array(PromptRepairGate.codeTokens(orig)),
            corrected: Array(PromptRepairGate.codeTokens(corr)),
            allowance: budget.dropAllowance,
            invented: .identifierInvented, dropped: .identifiersDropped
        ) { return rejection }

        // The one failure with no upside. A passage that forbade something and
        // now permits it has been inverted, and whatever it is pasted into will
        // carry the inversion. Checked as presence rather than per line, because
        // a merge legitimately changes which line the prohibition sits on.
        //
        // Compared with the self-correction cues stripped out, because several of
        // them *are* negations — "actually no", "no wait", "不對". Merging removes
        // the marker by design, so comparing the raw text rejected every
        // successful merge as an inverted meaning. Only a prohibition that
        // survives cue-stripping was ever a prohibition.
        // A-not-A question forms are stripped for the same reason as the cues:
        // 是不是 / 要不要 / 可不可以 are built out of 不 and forbid nothing, so a
        // dictated question tidied into a statement read as a lost prohibition.
        // Any Chinese dictation containing one could not be tidied at all.
        if SymbolCompressor.isNegated(negationEvidence(in: orig)),
           !SymbolCompressor.isNegated(negationEvidence(in: corr)) {
            return .negationLost
        }

        guard orig.count <= maxDistanceComparison, corr.count <= maxDistanceComparison
        else { return nil }
        let a = Array(orig.lowercased()), b = Array(corr.lowercased())
        let denom = max(a.count, b.count)
        guard denom > 0 else { return .empty }
        let distance = Double(TranscriptCorrectionGate.levenshtein(a, b)) / Double(denom)
        // The same reasoning as the deletion allowance, in the other unit: a
        // passage that is a quarter padding cannot have that padding removed
        // without moving its edit distance by about a quarter, so the distance
        // budget has to follow the same measurement or the second rule rejects
        // what the first one just allowed.
        let allowed = editBudget
            + min(maxCueEditBonus, Double(budget.cues) * editBudgetPerCue)
            + min(maxPaddingEditBonus, budget.paddingShare * 1.5)
        return distance <= allowed ? nil : .tooDifferent
    }

    /// The text a negation check should look at: what remains once the
    /// constructions that merely *contain* a negation marker are removed.
    static func negationEvidence(in text: String) -> String {
        ChineseQuestionForms.stripped(from: SelfCorrectionCues.stripped(from: text))
    }

    public static func accepts(
        original: String, corrected: String, budget: DeletionBudget? = nil
    ) -> Bool {
        rejection(original: original, corrected: corrected, budget: budget) == nil
    }

    /// Whether the output repeats itself in a way the input did not.
    ///
    /// A 4-bit quantized model can fall into a token-repetition loop, which
    /// `QwenModelHost` documents and mitigates with a repetition penalty over a
    /// 20-token window. A whole-passage repair generates ten times as many tokens
    /// as anything else in this app, so a loop with a longer period than that
    /// window is both likelier and invisible to the penalty. This is the backstop
    /// that does not depend on the sampler.
    static func looped(_ corrected: String, original: String) -> Bool {
        // Scanned as unicode scalars, not as `Character`s. Window comparison is
        // the inner loop, and `Character ==` compares grapheme clusters — an
        // order of magnitude dearer than comparing two `UInt32`s. A window is 24
        // scalars rather than 24 graphemes now; for the text this sees that is
        // the same thing, and loop detection does not care either way.
        let text = Array(corrected.unicodeScalars)
        guard text.count >= loopWindow * loopLimit else { return false }

        // The original is indexed **once**, not searched per window.
        //
        // This is where the time actually went, and neither the string-keyed
        // original nor my first rewrite of it saw that: "does the original also
        // contain this window three times?" was answered with
        // `String.range(of:)`, a Unicode-aware search restarted for every
        // repeated window. Measured in a release build on 6,869 characters of
        // ordinary prose — the realistic case, not the pathological one — that
        // was 132 ms per call. Building the same rolling-hash index over the
        // original makes the whole function O(n + m) and the same input 1 ms.
        let source = Array(original.unicodeScalars)
        let sourceWindows = Self.windowIndex(source)

        var seen: [UInt64: Window] = [:]
        var hash: UInt64 = 0
        var highestPower: UInt64 = 1
        for offset in 0..<loopWindow {
            hash = hash &* loopHashBase &+ UInt64(text[offset].value)
            if offset > 0 { highestPower = highestPower &* loopHashBase }
        }

        var start = 0
        while true {
            if var entry = seen[hash],
               Self.windowsMatch(text, entry.start, text, start, loopWindow) {
                entry.count += 1
                if entry.count >= loopLimit, !entry.askedTheOriginal {
                    // Only a repeat the original did not already contain: a
                    // dictated passage may legitimately repeat a phrase.
                    let inOriginal = sourceWindows[hash].map {
                        Self.windowsMatch(source, $0.start, text, start, loopWindow) ? $0.count : 0
                    } ?? 0
                    if inOriginal < loopLimit { return true }
                    // Asked once. The condition stays true for every later
                    // position of the same window.
                    entry.askedTheOriginal = true
                }
                seen[hash] = entry
            } else {
                seen[hash] = Window(start: start, count: 1, askedTheOriginal: false)
            }

            guard start + loopWindow < text.count else { break }
            hash = (hash &- UInt64(text[start].value) &* highestPower)
                &* loopHashBase &+ UInt64(text[start + loopWindow].value)
            start += 1
        }
        return false
    }

    /// One entry per distinct window: where it was first seen, how many times it
    /// recurred, and — for the corrected text — whether the original has already
    /// been asked about it.
    ///
    /// A value, not an array of positions. Buckets of `[Int]` meant a fresh
    /// `Array` allocation at every position of a passage with no repeats in it,
    /// which is what ordinary prose is.
    ///
    /// Collisions are ignored rather than chained: a 64-bit polynomial hash over
    /// a few thousand windows collides with probability around 1e-12, and the
    /// window is compared for real before any count is believed.
    private struct Window {
        let start: Int
        var count: Int
        var askedTheOriginal: Bool
    }

    /// Every distinct window of `text`, with how often it occurs (counting
    /// stops at `loopLimit` — nothing above it changes an answer).
    private static func windowIndex(
        _ text: [Unicode.Scalar]
    ) -> [UInt64: (start: Int, count: Int)] {
        var index: [UInt64: (start: Int, count: Int)] = [:]
        guard text.count >= loopWindow else { return index }

        var hash: UInt64 = 0
        var highestPower: UInt64 = 1
        for offset in 0..<loopWindow {
            hash = hash &* loopHashBase &+ UInt64(text[offset].value)
            if offset > 0 { highestPower = highestPower &* loopHashBase }
        }

        var start = 0
        while true {
            if var entry = index[hash],
               Self.windowsMatch(text, entry.start, text, start, loopWindow) {
                if entry.count < loopLimit {
                    entry.count += 1
                    index[hash] = entry
                }
            } else {
                index[hash] = (start: start, count: 1)
            }
            guard start + loopWindow < text.count else { break }
            hash = (hash &- UInt64(text[start].value) &* highestPower)
                &* loopHashBase &+ UInt64(text[start + loopWindow].value)
            start += 1
        }
        return index
    }

    /// The windows themselves compared, so a hash collision cannot invent a
    /// repeat.
    private static func windowsMatch(
        _ a: [Unicode.Scalar], _ ai: Int, _ b: [Unicode.Scalar], _ bi: Int, _ length: Int
    ) -> Bool {
        for offset in 0..<length where a[ai + offset] != b[bi + offset] { return false }
        return true
    }

    /// Characters per window. Long enough that ordinary repeated phrasing does
    /// not trip it, short enough to catch a clause-length loop.
    static let loopWindow = 24
    /// How many times a window must repeat before it counts as a loop.
    static let loopLimit = 3
    /// An odd multiplier, so the rolling hash spreads across the whole range.
    private static let loopHashBase: UInt64 = 1_000_003


    // MARK: - Helpers

    /// Invention is fatal; disappearance is bounded.
    ///
    /// Both directions matter and they are not symmetrical. A number or an
    /// identifier the user never said is a fabrication that reads as fact —
    /// there is no amount of it that is acceptable. One that vanishes is what a
    /// self-correction looks like, so a few are expected and a flood is the model
    /// summarizing.
    static func subsetRejection(
        original: [String], corrected: [String], allowance: Int,
        invented: Rejection, dropped: Rejection
    ) -> Rejection? {
        var remaining = counted(original)
        for token in corrected {
            guard let count = remaining[token], count > 0 else { return invented }
            remaining[token] = count - 1
        }
        let vanished = remaining.values.reduce(0, +)
        return vanished > allowance ? dropped : nil
    }

    static func counted(_ tokens: [String]) -> [String: Int] {
        tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Lines that say something. Blank lines are not counted, so a model that
    /// double-spaces a passage is not accused of adding content.
    static func contentLineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n")
            .count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
