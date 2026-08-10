import Foundation
import Testing
@testable import FlowTranslateCore

/// What the rulebook actually buys, measured the way the literature measures it.
///
/// Compact Constraint Encoding for LLM Code Generation (arXiv 2604.07192)
/// compares one prompt's constraint section written compactly against the same
/// section written out, and reports a ~71% cut with no measurable change in
/// whether the constraints are obeyed. That is the comparison here: one IR,
/// rendered twice, differing only in symbol mode.
///
/// It is emphatically *not* a comparison against the raw spoken request. A
/// compiled prompt says more than the sentence it came from — that is the point
/// of compiling it — so measuring against the request reports the added
/// structure as a compression failure.
@Suite("What symbols actually save")
struct SymbolSavingTests {

    private func ir() -> PromptIR {
        PromptIR(
            goal: "Add exponential-backoff retry to the uploader",
            context: ["Sources/Uploader.swift fails on transient 5xx errors"],
            constraints: ["Do not add new third-party dependencies",
                          "All existing tests must pass"],
            scopeExclusions: ["Do not change any public API"],
            acceptance: ["Transient 5xx is retried rather than failing"]
        )
    }

    private func render(_ mode: PromptSymbolMode, _ layout: PromptLayout) -> PromptArtifact {
        PromptRenderer.render(
            ir(),
            options: PromptRenderOptions(
                symbolMode: mode,
                syncedSymbols: Set(PromptStdlib.all.symbols),
                layout: layout
            )
        )
    }

    @Test("bare symbols are materially cheaper than their expansions")
    func symbolsSaveTokens() {
        for layout in PromptLayout.allCases {
            let expanded = render(.off, layout)
            let symbolic = render(.symbolsAssumeRulebook, layout)
            #expect(!symbolic.usedSymbols.isEmpty, "\(layout) produced no symbols")
            #expect(
                symbolic.estimatedTokens < expanded.estimatedTokens,
                "\(layout): \(expanded.estimatedTokens) → \(symbolic.estimatedTokens)"
            )
        }
    }

    /// A counter-intuitive rule compresses to `SYMBOL — reason`: the symbol
    /// because the encoding study measured format as irrelevant to compliance,
    /// and the reason because stating *why* is the part that is not.
    @Test("a counter-intuitive rule compresses, and keeps its reason")
    func counterIntuitiveRulesCompressWithTheirReason() {
        let workflowIR = PromptIR(
            goal: "Refactor the uploader",
            constraints: ["explain before implementing", "don't guess, ask"]
        )
        let artifact = PromptRenderer.render(
            workflowIR,
            options: PromptRenderOptions(
                symbolMode: .symbolsAssumeRulebook,
                syncedSymbols: Set(PromptStdlib.all.symbols)
            )
        )
        #expect(artifact.usedSymbols.contains("EXPLAIN_FIRST"))
        #expect(artifact.content.contains("EXPLAIN_FIRST"))
        // Bare: the reason is fixed content and lives in the synced rules file,
        // so the prompt pays three tokens instead of twenty-eight.
        #expect(!artifact.content.contains("unrequested edit"), "\(artifact.content)")
        // …and the long-form wording it replaced is not there either.
        #expect(!artifact.content.contains("Explain what you are going to change"))
    }

    /// The saving this change bought, measured rather than asserted: eleven of
    /// the fifty-two rules used to be spelled out in full at every mode.
    @Test("compressing the counter-intuitive rules is a material saving")
    func counterIntuitiveCompressionSaves() {
        let ir = PromptIR(
            goal: "Review this PR",
            constraints: ["explain before implementing", "search the web", "先研究"],
            acceptance: ["report everything then filter"]
        )
        func render(_ mode: PromptSymbolMode, expanded: Bool = false) -> Int {
            PromptRenderer.render(ir, options: PromptRenderOptions(
                symbolMode: mode, syncedSymbols: Set(PromptStdlib.all.symbols),
                expandsRecognisedConstraints: expanded
            )).estimatedTokens
        }
        let symbolic = render(.symbolsAssumeRulebook)
        // The baseline is these constraints in the rulebook's full wording — what
        // the reader would have to read without the symbols. Plain `off` is the
        // user's own three words and is not what is being compared against.
        let spelledOut = render(.off, expanded: true)
        #expect(symbolic < spelledOut, "\(symbolic) vs \(spelledOut)")
    }

    /// A prompt with nothing the rulebook recognises must not claim a saving.
    @Test("an unrecognised constraint yields no symbols")
    func nothingToCompressIsNotASaving() {
        let plain = PromptIR(
            goal: "Rename the widget",
            constraints: ["Keep the icon exactly 24 points wide"]
        )
        let artifact = PromptRenderer.render(
            plain, options: PromptRenderOptions(symbolMode: .symbolsAssumeRulebook)
        )
        #expect(artifact.usedSymbols.isEmpty)
    }
}

/// Regressions found by running the corpus through the real model. Each was
/// invisible to the deterministic tests and to reading the output, which is the
/// argument for having a live eval at all.
@Suite("Live-eval regressions")
struct LiveEvalRegressionTests {

    /// A symbol says *what* but not *whose*. `KEEP_API` cannot express "of
    /// OrderRepository", so compressing a scoped constraint into it widens the
    /// instruction and deletes the identifier — and the prompt still reads
    /// perfectly afterwards.
    @Test("a constraint naming an identifier keeps its sentence")
    func scopedConstraintsAreNotCompressed() {
        let scoped = [
            "不要動 OrderRepository 的公開 API",
            "Never add new dependencies to Package.swift",
            "不要重構 AudioRouter.swift 以外的東西",
        ]
        for item in scoped {
            let result = SymbolCompressor.compress(
                PromptIR(goal: "x", constraints: [item]), rulebook: PromptStdlib.all
            )
            #expect(result.usedSymbols.isEmpty, "\(item) was compressed away")
            #expect(result.ir.constraints == [item])
        }
    }

    /// The guard must not disable compression wholesale: an unscoped constraint
    /// mentioning a term the rule itself uses still collapses.
    @Test("an unscoped constraint still compresses")
    func genericConstraintsStillCompress() {
        for item in ["不要動公開的 API", "Don't change the public API", "no new dependencies"] {
            let result = SymbolCompressor.compress(
                PromptIR(goal: "x", constraints: [item]), rulebook: PromptStdlib.all
            )
            #expect(!result.usedSymbols.isEmpty, "\(item) failed to compress")
        }
    }

    /// PascalCase is every Swift type name, and no span-level rule could see it.
    @Test("PascalCase type names are recognised as code")
    func pascalCaseIsCode() {
        for name in ["OrderRepository", "RetryPolicy", "AudioRouter"] {
            let spans = LexicalCompressor.codeSpans(in: "change \(name) please")
            #expect(spans.contains { name.contains(String("change \(name) please"[$0])) },
                    "\(name) was not seen as an identifier")
        }
        // Ordinary sentence-initial words must not be mistaken for identifiers,
        // or the compressor would refuse to touch normal prose.
        #expect(LexicalCompressor.codeSpans(in: "Never reformat the file").isEmpty)
    }

    /// The model paraphrases, so a short phrase list under-matches. This rule
    /// was missed entirely on a live run.
    @Test("MEASURE_FIRST is reachable from the phrasings a model produces")
    func measureFirstMatchesParaphrases() {
        let book = PromptStdlib.all
        for phrase in ["measure before you change anything", "profile before optimizing",
                       "benchmark first", "先量測", "量測後再最佳化"] {
            #expect(SymbolCompressor.match(phrase, in: book) == "MEASURE_FIRST",
                    "\(phrase) did not resolve")
        }
    }
}
