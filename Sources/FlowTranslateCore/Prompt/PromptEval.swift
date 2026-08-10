import Foundation

/// One graded example: a request, and what a correct compilation of it must
/// contain.
///
/// Expectations are deliberately *necessary conditions* rather than an exact
/// expected output. There is no single correct phrasing of a prompt, so
/// asserting on one would measure conformity to whatever the model happened to
/// produce the day the fixture was written. What can be asserted is that the
/// terms survive, the constraints are found, the negations are intact, and the
/// result is shorter.
public struct PromptEvalCase: Sendable, Equatable, Identifiable {
    public var id: String
    /// The request as a user would speak or type it.
    public var input: String
    public var language: PromptOutputLanguage
    /// Substrings that must appear verbatim in the rendered prompt. Identifiers,
    /// paths, numbers, versions — anything whose alteration breaks the task.
    public var requiredTerms: [String]
    /// Words the goal must convey. Matched case-insensitively against the goal
    /// and, failing that, the whole prompt.
    public var goalKeywords: [String]
    /// Rule symbols the compiler should recognise in this request.
    public var expectedSymbols: [String]
    /// Substrings that must NOT survive — filler the compressor should remove.
    public var forbiddenTerms: [String]
    /// Whether the request forbids something. When true, the output must still
    /// read as a prohibition.
    public var isNegated: Bool
    /// Structural tags the rendered prompt must contain.
    ///
    /// The other expectations all check *content*, which cannot see the one
    /// failure that matters most for a question: a prompt that answers it as an
    /// instruction keeps every term and every keyword, and is still the opposite
    /// of what was asked. Only the shape gives it away.
    public var requiredTags: [String]

    public init(
        id: String,
        input: String,
        language: PromptOutputLanguage = .english,
        requiredTerms: [String] = [],
        goalKeywords: [String] = [],
        expectedSymbols: [String] = [],
        forbiddenTerms: [String] = [],
        isNegated: Bool = false,
        requiredTags: [String] = []
    ) {
        self.id = id
        self.input = input
        self.language = language
        self.requiredTerms = requiredTerms
        self.goalKeywords = goalKeywords
        self.expectedSymbols = expectedSymbols
        self.forbiddenTerms = forbiddenTerms
        self.isNegated = isNegated
        self.requiredTags = requiredTags
    }
}

/// What one case scored.
public struct PromptEvalResult: Sendable, Equatable {
    public var caseID: String
    /// The model returned something that parsed as an IR.
    public var parsed: Bool
    /// Fraction of `requiredTerms` present in the output.
    public var termRecall: Double
    /// Fraction of `goalKeywords` present.
    public var goalRecall: Double
    /// Fraction of `expectedSymbols` the compressor found.
    public var symbolRecall: Double
    /// True when no forbidden term survived.
    public var fillerRemoved: Bool
    /// True when a prohibition still reads as one.
    public var negationPreserved: Bool
    /// True when the rendered prompt had every structural tag the case demands.
    public var shapeCorrect: Bool
    public var inputTokens: Int
    public var outputTokens: Int
    /// Free-text notes for the failures, so a scorecard says *what* broke.
    public var failures: [String]

    /// How much longer the compiled prompt is than the request it came from.
    ///
    /// Deliberately **not** called a compression ratio. A compiled prompt is
    /// supposed to be longer than what was dictated: it states the scope
    /// boundary, the acceptance criterion and the structure that the spoken
    /// sentence left implicit. Reporting that as negative compression made the
    /// pipeline look broken when it was working — unstructured input against a
    /// structured specification is not a before/after of the same thing.
    ///
    /// What the symbol rulebook actually saves is measured separately, by
    /// rendering one IR twice: once with symbols and once expanded.
    public var structureOverhead: Double {
        guard inputTokens > 0 else { return 0 }
        return Double(outputTokens) / Double(inputTokens) - 1
    }

    /// A single number for tracking movement between runs.
    ///
    /// Term recall and negation dominate because they are correctness; symbol
    /// recall and compression are efficiency, and efficiency that loses a term
    /// is not a win.
    public var score: Double {
        guard parsed else { return 0 }
        var total = 0.0
        total += termRecall * 0.35
        total += (negationPreserved ? 1.0 : 0.0) * 0.25
        total += goalRecall * 0.20
        total += symbolRecall * 0.10
        total += (fillerRemoved ? 1.0 : 0.0) * 0.10
        return total
    }

    public var passed: Bool {
        parsed && termRecall == 1 && negationPreserved && goalRecall >= 0.5 && shapeCorrect
    }
}

/// Scores a compiled prompt against a case.
///
/// Pure value logic so the deterministic half of the pipeline can be graded in
/// CI with recorded model output, while the same scorer grades live model runs
/// from the app. Without this, "the feature is too weak" is unfalsifiable and
/// so is any claim to have fixed it.
public enum PromptEvalScorer {

    public static func score(
        _ evalCase: PromptEvalCase,
        ir: PromptIR?,
        rendered: String
    ) -> PromptEvalResult {
        var failures: [String] = []
        let haystack = rendered.lowercased()

        guard let ir, ir.isActionable else {
            return PromptEvalResult(
                caseID: evalCase.id, parsed: false, termRecall: 0, goalRecall: 0,
                symbolRecall: 0, fillerRemoved: false, negationPreserved: false,
                shapeCorrect: false,
                inputTokens: TokenEstimator.estimate(evalCase.input),
                outputTokens: TokenEstimator.estimate(rendered),
                failures: ["no usable IR"]
            )
        }

        // Terms are matched case-sensitively: `maxRetryCount` and
        // `maxretrycount` are not the same identifier.
        let missingTerms = evalCase.requiredTerms.filter { !rendered.contains($0) }
        if !missingTerms.isEmpty { failures.append("lost terms: \(missingTerms.joined(separator: ", "))") }
        let termRecall = fraction(evalCase.requiredTerms.count - missingTerms.count,
                                  of: evalCase.requiredTerms.count)

        let missingGoal = evalCase.goalKeywords.filter { !haystack.contains($0.lowercased()) }
        if !missingGoal.isEmpty { failures.append("goal missing: \(missingGoal.joined(separator: ", "))") }
        let goalRecall = fraction(evalCase.goalKeywords.count - missingGoal.count,
                                  of: evalCase.goalKeywords.count)

        let allBullets = ir.constraints + ir.scopeExclusions + ir.acceptance
        let missingSymbols = evalCase.expectedSymbols.filter { symbol in
            !allBullets.contains(symbol) && !rendered.contains(symbol)
        }
        if !missingSymbols.isEmpty {
            failures.append("symbols not found: \(missingSymbols.joined(separator: ", "))")
        }
        let symbolRecall = fraction(evalCase.expectedSymbols.count - missingSymbols.count,
                                    of: evalCase.expectedSymbols.count)

        let survivingFiller = evalCase.forbiddenTerms.filter { haystack.contains($0.lowercased()) }
        if !survivingFiller.isEmpty {
            failures.append("filler survived: \(survivingFiller.joined(separator: ", "))")
        }

        // A prohibition that stops reading as one has been inverted — the single
        // most damaging failure the pipeline can have.
        let negationPreserved = !evalCase.isNegated || readsAsProhibition(rendered)
        if !negationPreserved { failures.append("NEGATION LOST — meaning inverted") }

        let missingTags = evalCase.requiredTags.filter { !rendered.contains($0) }
        if !missingTags.isEmpty {
            failures.append("WRONG SHAPE — missing \(missingTags.joined(separator: ", "))")
        }

        return PromptEvalResult(
            caseID: evalCase.id, parsed: true,
            termRecall: termRecall, goalRecall: goalRecall, symbolRecall: symbolRecall,
            fillerRemoved: survivingFiller.isEmpty, negationPreserved: negationPreserved,
            shapeCorrect: missingTags.isEmpty,
            inputTokens: TokenEstimator.estimate(evalCase.input),
            outputTokens: TokenEstimator.estimate(rendered),
            failures: failures
        )
    }

    /// Whether the text still forbids something — either in words, or via a
    /// symbol whose whole meaning is a prohibition.
    static func readsAsProhibition(_ text: String) -> Bool {
        if SymbolCompressor.isNegated(text) { return true }
        let prohibitionSymbols = ["NO_DEPS", "NO_REFACTOR", "KEEP_API", "NO_SKIP_TESTS",
                                  "NO_MAGIC_NUMBERS", "NO_SECRETS_IN_CODE", "NO_EVAL",
                                  "NO_FORCE_PUSH", "NO_COMPAT_SHIMS", "MIN_DIFF",
                                  "NO_N_PLUS_ONE", "NO_AI_ATTRIBUTION", "DO NOT"]
        return prohibitionSymbols.contains { text.contains($0) }
    }

    static func fraction(_ hits: Int, of total: Int) -> Double {
        total == 0 ? 1 : Double(hits) / Double(total)
    }
}

/// An aggregate scorecard over a whole eval run.
public struct PromptEvalReport: Sendable {
    public var results: [PromptEvalResult]

    public init(results: [PromptEvalResult]) { self.results = results }

    public var parseRate: Double { rate { $0.parsed } }
    public var passRate: Double { rate { $0.passed } }
    public var meanScore: Double { mean(\.score) }
    public var meanTermRecall: Double { mean(\.termRecall) }
    public var meanSymbolRecall: Double { mean(\.symbolRecall) }
    public var meanStructureOverhead: Double { mean(\.structureOverhead) }
    /// Cases where a prohibition was inverted. Must always be zero.
    public var negationFailures: [String] {
        results.filter { !$0.negationPreserved }.map(\.caseID)
    }

    private func rate(_ predicate: (PromptEvalResult) -> Bool) -> Double {
        guard !results.isEmpty else { return 0 }
        return Double(results.filter(predicate).count) / Double(results.count)
    }

    private func mean(_ path: KeyPath<PromptEvalResult, Double>) -> Double {
        guard !results.isEmpty else { return 0 }
        return results.map { $0[keyPath: path] }.reduce(0, +) / Double(results.count)
    }

    /// A scorecard meant to be pasted into a commit message or a PR.
    public var summary: String {
        func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        var lines = [
            "cases          \(results.count)",
            "parse rate     \(pct(parseRate))",
            "pass rate      \(pct(passRate))",
            "mean score     \(String(format: "%.3f", meanScore))",
            "term recall    \(pct(meanTermRecall))",
            "symbol recall  \(pct(meanSymbolRecall))",
            "structure      +\(pct(meanStructureOverhead)) vs raw request",
        ]
        if !negationFailures.isEmpty {
            lines.append("NEGATION LOST  \(negationFailures.joined(separator: ", "))")
        }
        let failing = results.filter { !$0.passed }
        if !failing.isEmpty {
            lines.append("")
            lines.append("failures:")
            for result in failing {
                lines.append("  \(result.caseID): \(result.failures.joined(separator: "; "))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
