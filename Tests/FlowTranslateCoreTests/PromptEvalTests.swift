import Foundation
import Testing
@testable import FlowTranslateCore

/// Grades the deterministic half of the pipeline — salvage → optimize →
/// compress → render — over the whole eval set.
///
/// This runs with no model, which is the point: it is the floor. Whatever the
/// model does, the deterministic stages must never drop an identifier or invert
/// a prohibition, and if they do it should fail here rather than in front of a
/// user. The same `PromptEvalScorer` grades live model output from the app, so
/// the two numbers are directly comparable.
@Suite("Prompt eval — deterministic floor")
struct PromptEvalTests {

    /// What the section tags themselves may cost. Six sections at roughly two
    /// tokens per open/close pair; anything beyond this is the compressor
    /// failing, not the layout.
    static let layoutScaffoldingBudget = 12

    /// Any CJK at all puts a case in the "cannot be pruned" bucket. Dominance is
    /// the wrong test: a code-switched request is mostly Chinese grammar holding
    /// English terms together, and the Chinese half is what resists pruning.
    private func containsCJK(_ text: String) -> Bool {
        text.contains { TokenEstimator.isCJK($0) }
    }

    private func renderSalvaged(_ evalCase: PromptEvalCase) -> (PromptIR, String) {
        let ir = PromptOptimizer.optimize(PromptIRParser.salvage(from: evalCase.input))
        let artifact = PromptRenderer.render(
            ir,
            options: PromptRenderOptions(language: evalCase.language, compression: .balanced)
        )
        return (ir, artifact.content)
    }

    @Test("every case produces a usable IR")
    func everyCaseParses() {
        for evalCase in PromptEvalCases.all {
            let (ir, rendered) = renderSalvaged(evalCase)
            let result = PromptEvalScorer.score(evalCase, ir: ir, rendered: rendered)
            #expect(result.parsed, "\(evalCase.id) produced no usable IR")
        }
    }

    /// The one that must never regress. Losing a path or an identifier sends the
    /// agent to edit the wrong file, and the prompt still *reads* fine — which
    /// is exactly why it needs a test rather than a human reading the output.
    @Test("identifiers, paths and numbers survive every case")
    func termRecallIsTotal() {
        for evalCase in PromptEvalCases.all {
            let (ir, rendered) = renderSalvaged(evalCase)
            let result = PromptEvalScorer.score(evalCase, ir: ir, rendered: rendered)
            #expect(
                result.termRecall == 1,
                "\(evalCase.id): \(result.failures.joined(separator: "; "))\n\(rendered)"
            )
        }
    }

    /// A prohibition that stops reading as one is the worst failure available:
    /// the agent does the opposite of what was asked, confidently.
    @Test("prohibitions still read as prohibitions")
    func negationSurvivesEveryCase() {
        for evalCase in PromptEvalCases.all where evalCase.isNegated {
            let (ir, rendered) = renderSalvaged(evalCase)
            let result = PromptEvalScorer.score(evalCase, ir: ir, rendered: rendered)
            #expect(result.negationPreserved, "\(evalCase.id) inverted:\n\(rendered)")
        }
    }

    /// The compressor is allowed to be unhelpful; it is not allowed to be
    /// wrong. `adv-inverted-constraint` asks to *add* a dependency using almost
    /// the same words `en-retry` uses to forbid one.
    @Test("a request to add a dependency never compresses to NO_DEPS")
    func polarityIsNotConfused() {
        let evalCase = PromptEvalCases.adversarial.first { $0.id == "adv-inverted-constraint" }!
        let (_, rendered) = renderSalvaged(evalCase)
        #expect(!rendered.contains("NO_DEPS"))
        #expect(rendered.contains("swift-log"))
    }

    /// English is the only script the compressor can actually prune — Apple's
    /// `NLTagger` returns no part of speech and no lemma for Chinese, so a
    /// Chinese request leaves the deterministic stages the same length it
    /// arrived. That is stated here rather than hidden, because it is also what
    /// the settings pane tells the user.
    @Test("English prompts come out shorter than they went in")
    func englishCompressionNeverInflates() {
        // The XML scaffolding is a real, accepted cost: `<constraints>` and its
        // closing tag run about six tokens where the old `CONSTRAINTS:` label
        // ran two. It buys the structure Anthropic documents as the one that
        // parses unambiguously, so the budget below accounts for it rather than
        // pretending the layout is free.
        for evalCase in PromptEvalCases.all where !containsCJK(evalCase.input) {
            let (_, rendered) = renderSalvaged(evalCase)
            let inputTokens = TokenEstimator.estimate(evalCase.input)
            let outputTokens = TokenEstimator.estimate(rendered)
            // Below this the `TASK:`/`CONTEXT:` scaffolding dominates and the
            // ratio measures the labels, not the compressor.
            guard inputTokens > 20 else { continue }
            #expect(
                outputTokens <= inputTokens + Self.layoutScaffoldingBudget,
                "\(evalCase.id): \(inputTokens) → \(outputTokens)\n\(rendered)"
            )
        }
    }

    /// Chinese may not shrink, but it must not balloon either: the only growth
    /// allowed is the section labels — plus, for a question, the fixed
    /// answer-first block, which is content rather than scaffolding and is the
    /// whole reason a question renders differently from a task.
    @Test("Chinese prompts grow by no more than the section labels")
    func chineseOverheadIsBounded() {
        for evalCase in PromptEvalCases.all where containsCJK(evalCase.input) {
            let (_, rendered) = renderSalvaged(evalCase)
            let overhead = TokenEstimator.estimate(rendered) - TokenEstimator.estimate(evalCase.input)
            var budget = Self.layoutScaffoldingBudget
            if rendered.contains("<answer_first>") {
                // The whole block, tags included — the tag pair is part of what
                // the block costs, and the label budget was sized before this
                // section existed.
                budget += TokenEstimator.estimate(
                    "<answer_first>\(SectionTitles.answerOnlyBody(evalCase.language))</answer_first>"
                )
            }
            #expect(
                overhead <= budget,
                "\(evalCase.id) grew by \(overhead) tokens (budget \(budget))\n\(rendered)"
            )
        }
    }

    /// In a Chinese sentence, the English that survives is a term or a quoted
    /// error, never prose. Pruning it as prose rewrote the very error message
    /// the request was about.
    @Test("English terms embedded in Chinese are left intact")
    func embeddedEnglishTermsSurvive() {
        let evalCase = PromptEvalCases.chinese.first { $0.id == "zh-scope" }!
        let (_, rendered) = renderSalvaged(evalCase)
        #expect(rendered.contains("index out of range"), "\(rendered)")
    }

    /// Not an assertion on quality — a recorded baseline. Printed so a change
    /// to any stage shows up as a number rather than a vibe.
    @Test("baseline scorecard")
    func baseline() {
        let report = PromptEvalReport(
            results: PromptEvalCases.all.map { evalCase in
                let (ir, rendered) = renderSalvaged(evalCase)
                return PromptEvalScorer.score(evalCase, ir: ir, rendered: rendered)
            }
        )
        print("\n=== deterministic floor (no model) ===\n\(report.summary)\n")
        #expect(report.parseRate == 1)
        #expect(report.negationFailures.isEmpty)
    }
}

/// Tests of the scorer itself. A grading harness that scores a broken output as
/// passing is worse than none, so the scorer needs its own floor.
@Suite("Prompt eval — scorer")
struct PromptEvalScorerTests {

    private let sample = PromptEvalCase(
        id: "sample",
        input: "Add retry to Sources/Uploader.swift, don't add dependencies",
        requiredTerms: ["Sources/Uploader.swift"],
        goalKeywords: ["retry"],
        expectedSymbols: ["NO_DEPS"],
        forbiddenTerms: ["basically"],
        isNegated: true
    )

    @Test("a missing identifier is caught even when the prompt reads well")
    func missingTermIsCaught() {
        let ir = PromptIR(goal: "Add retry to the uploader", constraints: ["NO_DEPS"])
        let result = PromptEvalScorer.score(
            sample, ir: ir, rendered: "TASK: Add retry to the uploader\nCONSTRAINTS: NO_DEPS"
        )
        #expect(result.termRecall == 0)
        #expect(!result.passed)
    }

    /// Identifiers are case-sensitive. `maxretrycount` is not `maxRetryCount`,
    /// and an agent told to rename the former will not find it.
    @Test("term matching is case-sensitive")
    func termMatchingIsCaseSensitive() {
        let evalCase = PromptEvalCase(id: "c", input: "x", requiredTerms: ["maxRetryCount"])
        let result = PromptEvalScorer.score(
            evalCase, ir: PromptIR(goal: "rename maxretrycount"),
            rendered: "TASK: rename maxretrycount"
        )
        #expect(result.termRecall == 0)
    }

    @Test("goal matching is case-insensitive")
    func goalMatchingIsCaseInsensitive() {
        let evalCase = PromptEvalCase(id: "c", input: "x", goalKeywords: ["retry"])
        let result = PromptEvalScorer.score(
            evalCase, ir: PromptIR(goal: "Add Retry"), rendered: "TASK: Add Retry"
        )
        #expect(result.goalRecall == 1)
    }

    @Test("an inverted prohibition scores zero on negation")
    func invertedNegationIsCaught() {
        let ir = PromptIR(goal: "Add retry to Sources/Uploader.swift", constraints: ["Add dependencies"])
        let result = PromptEvalScorer.score(
            sample, ir: ir,
            rendered: "TASK: Add retry to Sources/Uploader.swift\nCONSTRAINTS: Add dependencies"
        )
        #expect(!result.negationPreserved)
        #expect(!result.passed)
        #expect(result.failures.contains { $0.contains("NEGATION") })
    }

    /// A symbol whose entire meaning is a prohibition counts as one. Requiring
    /// the word "not" would fail the compressed form, which is the form the
    /// feature exists to produce.
    @Test("a prohibition symbol counts as a preserved negation")
    func symbolCountsAsNegation() {
        #expect(PromptEvalScorer.readsAsProhibition("CONSTRAINTS: NO_DEPS"))
        #expect(PromptEvalScorer.readsAsProhibition("CONSTRAINTS: Do not add dependencies"))
        #expect(!PromptEvalScorer.readsAsProhibition("CONSTRAINTS: Add dependencies"))
    }

    @Test("an unparseable compile scores zero, not a partial credit")
    func unparseableScoresZero() {
        let result = PromptEvalScorer.score(sample, ir: nil, rendered: "")
        #expect(result.score == 0)
        #expect(!result.parsed)
    }

    @Test("an empty expectation list does not penalise the score")
    func emptyExpectationsAreNeutral() {
        let evalCase = PromptEvalCase(id: "c", input: "Ship it")
        let result = PromptEvalScorer.score(
            evalCase, ir: PromptIR(goal: "Ship it"), rendered: "TASK: Ship it"
        )
        #expect(result.termRecall == 1)
        #expect(result.goalRecall == 1)
        #expect(result.passed)
    }

    @Test("the report summarises failures by case")
    func reportNamesFailingCases() {
        let report = PromptEvalReport(results: [
            PromptEvalScorer.score(sample, ir: nil, rendered: ""),
            PromptEvalScorer.score(
                sample,
                ir: PromptIR(goal: "Add retry to Sources/Uploader.swift", constraints: ["NO_DEPS"]),
                rendered: "TASK: Add retry to Sources/Uploader.swift\nCONSTRAINTS: NO_DEPS"
            ),
        ])
        #expect(report.parseRate == 0.5)
        #expect(report.summary.contains("sample"))
    }
}

/// The output budget has to fit what the request actually asks for, not how
/// long it is. Reported from real use: a dense Chinese request lost its last
/// requirement ("最後…測試都沒問題才行") because the cap scaled on characters.
@Suite("Truncation detection")
struct TruncationTests {

    @Test("an unterminated JSON object is recognised as truncated")
    func detectsCutOffGeneration() {
        let cut = #"{"taskType":"refine","goal":"Add retry","constraints":["Do not add"#
        #expect(PromptIRParser.looksTruncated(cut))
        #expect(PromptIRParser.parse(cut) == nil)
    }

    @Test("a complete object is not reported as truncated")
    func completeOutputIsNotTruncated() {
        let whole = #"{"goal":"Add retry to the uploader"}"#
        #expect(!PromptIRParser.looksTruncated(whole))
    }

    /// Prose with no JSON at all is a different failure — the model ignored the
    /// schema — and must not be blamed on the token budget.
    @Test("prose is unparseable but not truncated")
    func proseIsNotTruncated() {
        #expect(!PromptIRParser.looksTruncated("Sure! Here is what I would do."))
    }

    @Test("an unterminated string counts as truncated")
    func cutInsideAStringIsTruncated() {
        #expect(PromptIRParser.looksTruncated(#"{"goal":"Add retry to the up"#))
    }
}
