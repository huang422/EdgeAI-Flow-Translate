import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct SymbolCompressorTests {

    private let rulebook = PromptStdlib.all

    // MARK: - Matching

    @Test func matchesTheExpansionItself() {
        #expect(SymbolCompressor.match("Do not add new third-party dependencies.", in: rulebook) == "NO_DEPS")
    }

    @Test func matchesAParaphrase() {
        #expect(SymbolCompressor.match("Please do not add any new third-party dependencies", in: rulebook) == "NO_DEPS")
    }

    @Test func bothLanguagesLandOnTheSameSymbol() {
        // The point of bilingual aliases: what the user says should not change
        // which rule they get.
        #expect(SymbolCompressor.match("不要加套件", in: rulebook) == "NO_DEPS")
        #expect(SymbolCompressor.match("不要新增任何第三方套件", in: rulebook) == "NO_DEPS")
        #expect(SymbolCompressor.match("no new libraries", in: rulebook) == "NO_DEPS")
    }

    @Test func passesThroughASymbolTheModelAlreadyEmitted() {
        // The intent-extraction prompt carries the catalogue and is asked to
        // emit symbols directly; that has to survive the backstop untouched.
        #expect(SymbolCompressor.match("NO_DEPS", in: rulebook) == "NO_DEPS")
    }

    @Test func negationGuardStopsTheMatcherInvertingMeaning() {
        // This is the dangerous case. Token overlap alone rates "add new
        // third-party dependencies" as a near-perfect match for NO_DEPS, whose
        // meaning is the exact opposite.
        #expect(SymbolCompressor.match("Add new third-party dependencies where needed", in: rulebook) == nil)
        #expect(SymbolCompressor.match("要新增第三方套件", in: rulebook) == nil)
    }

    @Test func contractionsCountAsNegation() {
        // "don't" must not tokenize into "don" + "t" and read as positive.
        #expect(SymbolCompressor.isNegated("don't add packages") == true)
        #expect(SymbolCompressor.isNegated("dont add packages") == true)
        #expect(SymbolCompressor.isNegated("add packages") == false)
    }

    @Test func unrelatedConstraintsAreLeftAlone() {
        #expect(SymbolCompressor.match("Use four-space indentation", in: rulebook) == nil)
        #expect(SymbolCompressor.match("把設定寫進環境變數", in: rulebook) == nil)
    }

    @Test func aSingleSharedWordCannotCarryAMatch() {
        #expect(SymbolCompressor.overlap(["the"], ["the", "quick", "brown"]) == 0)
    }

    // MARK: - Compression

    @Test func compressesConstraintsAndReportsSymbols() {
        let ir = PromptIR(
            goal: "Add retry to the uploader",
            constraints: ["Do not add new third-party dependencies.", "Use four-space indentation"],
            acceptance: ["All existing tests must still pass."]
        )
        let result = SymbolCompressor.compress(ir, rulebook: rulebook)
        #expect(result.ir.constraints == ["NO_DEPS", "Use four-space indentation"])
        #expect(result.ir.acceptance == ["TEST_PASS"])
        #expect(result.usedSymbols == ["NO_DEPS", "TEST_PASS"])
    }

    @Test func compressionIsReversible() {
        // A symbol must always resolve back to the rule it stands for. It
        // resolves to the wording for the target agent rather than to the exact
        // input string — that is the point of per-backend wording — so the
        // invariant is "no bare symbol survives, and the meaning is restored".
        let ir = PromptIR(goal: "Ship it", constraints: ["Do not add new third-party dependencies."])
        let compressed = SymbolCompressor.compress(ir, rulebook: rulebook).ir
        #expect(compressed.constraints == ["NO_DEPS"])

        let expanded = SymbolCompressor.expand(compressed, rulebook: rulebook, language: .english)
        #expect(expanded.constraints.first?.contains("NO_DEPS") == false)
        #expect(expanded.constraints.first?.contains("already depends on") == true)
    }

    @Test func expansionFollowsTheTargetAgent() {
        // Same rule, different agent, different wording — Codex gets the terse
        // declarative, Claude the fuller instruction.
        let ir = PromptIR(goal: "Ship it", constraints: ["NO_DEPS"])
        let claude = SymbolCompressor.expand(ir, rulebook: rulebook, language: .english, backend: .claude)
        let codex = SymbolCompressor.expand(ir, rulebook: rulebook, language: .english, backend: .codex)
        #expect(claude.constraints != codex.constraints)
        #expect(codex.constraints == ["No new third-party dependencies."])
    }

    @Test func expansionFollowsOutputLanguage() {
        let ir = PromptIR(goal: "Ship it", constraints: ["NO_DEPS"])
        let english = SymbolCompressor.expand(ir, rulebook: rulebook, language: .english)
        let chinese = SymbolCompressor.expand(ir, rulebook: rulebook, language: .traditionalChinese)
        #expect(english.constraints.first?.contains("already depends on") == true)
        #expect(chinese.constraints == ["不要新增任何第三方相依套件。"])
    }

    @Test func repeatedSymbolsCollapse() {
        let ir = PromptIR(
            goal: "Ship it",
            constraints: ["Do not add new third-party dependencies.", "no new libraries"]
        )
        let result = SymbolCompressor.compress(ir, rulebook: rulebook)
        #expect(result.ir.constraints == ["NO_DEPS"])
    }

    // MARK: - Safety downgrade

    @Test func bareSymbolsDowngradeWhenTheRulebookIsNotSynced() {
        // A prompt referencing a symbol the project never defined leaves Claude
        // guessing, so the mode has to give way. It falls back to writing the
        // constraint out rather than to symbols-plus-legend: the legend emits
        // the symbol AND its definition, which costs strictly more than the
        // sentence alone, and this downgrade fires exactly when the user has
        // not synced anything — the common case.
        let mode = SymbolCompressor.effectiveMode(
            requested: .symbolsAssumeRulebook,
            usedSymbols: ["NO_DEPS"],
            syncedSymbols: []
        )
        #expect(mode == .off)
    }

    /// Three modes, each producing a genuinely different output. Named here so
    /// dropping one is a deliberate act with a failing test, not a silent
    /// change to what a saved setting means.
    @Test func everyModeProducesADistinctOutput() {
        let ir = PromptIR(goal: "Add retry", constraints: ["Do not add new dependencies"])
        let synced = Set(PromptStdlib.all.symbols)
        var seen: Set<String> = []
        for mode in PromptSymbolMode.allCases {
            let content = PromptRenderer.render(
                ir, options: .init(symbolMode: mode, syncedSymbols: synced)
            ).content
            #expect(seen.insert(content).inserted, "\(mode) duplicates another mode")
        }
        // Three, since `expandInline` was folded into `off`: from the IR the
        // app actually compiles, the two rendered identical bytes.
        #expect(PromptSymbolMode.allCases.count == 3)
    }

    /// "Keep my wording" must not silently ship an identifier nothing defines:
    /// the rulebook is skipped for phrasing, but a symbol the model emitted is
    /// still resolved.
    @Test func keepMyWordingStillResolvesEmittedSymbols() {
        let ir = PromptIR(goal: "Add retry", constraints: ["NO_DEPS"])
        let content = PromptRenderer.render(
            ir, options: .init(symbolMode: .off, syncedSymbols: [])
        ).content
        #expect(!content.contains("NO_DEPS"))
        #expect(content.contains("already depends on"))
    }

    /// Every mode names the behaviour, not the mechanism, and explains its cost.
    @Test func everyModeIsExplained() {
        for mode in PromptSymbolMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(mode.explanation.count > 20, "\(mode) has no usable explanation")
        }
    }

    @Test func bareSymbolsSurviveWhenEverySymbolIsSynced() {
        let mode = SymbolCompressor.effectiveMode(
            requested: .symbolsAssumeRulebook,
            usedSymbols: ["NO_DEPS", "TEST_PASS"],
            syncedSymbols: ["NO_DEPS", "TEST_PASS", "MIN_DIFF"]
        )
        #expect(mode == .symbolsAssumeRulebook)
    }

    @Test func otherModesAreNeverDowngraded() {
        for requested in [PromptSymbolMode.off] {
            let mode = SymbolCompressor.effectiveMode(
                requested: requested, usedSymbols: ["NO_DEPS"], syncedSymbols: []
            )
            #expect(mode == requested)
        }
    }

    @Test func legendResolvesEverySymbolUsed() {
        let legend = SymbolCompressor.legend(
            for: ["NO_DEPS", "TEST_PASS"], rulebook: rulebook, language: .english
        )
        #expect(legend.count == 2)
        #expect(legend[0].hasPrefix("NO_DEPS = "))
    }

    // MARK: - Rulebook validation

    @Test func stdlibIsValid() {
        #expect(PromptStdlib.all.validationErrors().isEmpty)
    }

    @Test func rejectsMalformedSymbols() {
        #expect(PromptRulebook.isValidSymbol("NO_DEPS") == true)
        #expect(PromptRulebook.isValidSymbol("TEST_PASS_2") == true)
        #expect(PromptRulebook.isValidSymbol("no_deps") == false)
        #expect(PromptRulebook.isValidSymbol("No-Deps") == false)
        #expect(PromptRulebook.isValidSymbol("") == false)
        #expect(PromptRulebook.isValidSymbol("不要加套件") == false)
    }

    @Test func reportsDuplicateSymbols() {
        let book = PromptRulebook(rules: [
            PromptRule(symbol: "NO_DEPS", description: "a", source: "s"),
            PromptRule(symbol: "NO_DEPS", description: "b", source: "s"),
        ])
        #expect(book.validationErrors().contains { $0.contains("more than once") })
    }
}

// MARK: - Phase 0 regressions

@Suite struct SymbolModeRegressionTests {

    /// `.off` used to hand the raw IR straight to the renderer. Combined with a
    /// system prompt that always advertised the symbol catalogue, a model that
    /// obeyed it emitted a bare `NO_DEPS` that shipped with no legend and no
    /// expansion — exactly the unresolvable prompt `effectiveMode` exists to
    /// prevent.
    @Test func offModeExpandsSymbolsRatherThanEmittingThemBare() {
        let ir = PromptIR(goal: "Ship it", constraints: ["NO_DEPS"], acceptance: ["TEST_PASS"])
        let content = PromptRenderer.render(
            ir, options: .init(kind: .prompt, symbolMode: .off, rulebook: PromptStdlib.all)
        ).content

        // Spelled out, not symbolized. Claude gets each rule's positive form
        // where one exists, so the assertion targets the meaning-bearing words
        // of that form rather than the prohibition it replaces.
        #expect(content.contains("already depends on"))
        #expect(content.contains("existing tests must still pass"))
        #expect(content.contains("NO_DEPS") == false)
        #expect(content.contains("TEST_PASS") == false)
    }

    @Test func everyModeResolvesEverySymbolItPrints() {
        // Whatever the mode, a reader must be able to resolve what they see:
        // either the text is spelled out, or a legend defines it, or the
        // rulebook is synced.
        let ir = PromptIR(goal: "Ship it", constraints: ["NO_DEPS"])
        for mode in PromptSymbolMode.allCases {
            let artifact = PromptRenderer.render(
                ir,
                options: .init(kind: .prompt, symbolMode: mode, rulebook: PromptStdlib.all, syncedSymbols: [])
            )
            let printsBareSymbol = artifact.content.contains("NO_DEPS")
                && artifact.content.contains("Do not add") == false
            let carriesLegend = artifact.content.contains("NO_DEPS = ")
            #expect(printsBareSymbol == false || carriesLegend,
                    "mode \(mode.rawValue) printed a symbol with no way to resolve it")
        }
    }

    /// Renaming a symbol in the editor collapsed the detail pane, because the
    /// rule's identity *was* its symbol text.
    @Test func ruleIdentityIsStableAcrossASymbolRename() {
        var rule = PromptRule(symbol: "NO_DEPS", description: "…", source: "s")
        let original = rule.id
        rule.symbol = "N"          // mid-typing state
        #expect(rule.id == original)
    }

    @Test func rulebookDecodesWithoutIdsFromOlderSaves() throws {
        let legacy = #"{"rules":[{"symbol":"NO_DEPS","description":"Do not add deps.","source":"s"}]}"#
        let book = try JSONDecoder().decode(PromptRulebook.self, from: Data(legacy.utf8))
        #expect(book.rules.count == 1)
        #expect(book.rules[0].symbol == "NO_DEPS")
    }
}

/// The model routinely states one requirement twice — "測試要過" as a constraint
/// and "既有測試全數通過" as an acceptance criterion — and both compress to
/// `TEST_PASS`. Deduplication within a section cannot see that; once the symbol
/// is expanded it becomes the same twelve-token sentence under two headings.
@Suite("Cross-section repeats")
struct CrossSectionRepeatTests {

    private func compress(_ ir: PromptIR) -> PromptIR {
        SymbolCompressor.compress(ir, rulebook: PromptStdlib.all).ir
    }

    @Test("a symbol stated in two sections is kept in the first")
    func keepsTheFirstOccurrence() {
        let out = compress(PromptIR(
            goal: "Refactor uploadChunk",
            constraints: ["tests must pass"],
            acceptance: ["existing tests must pass"]
        ))
        #expect(out.constraints == ["TEST_PASS"])
        #expect(out.acceptance.isEmpty)
    }

    @Test("the rendered prompt states the rule once")
    func renderedOnce() {
        let ir = PromptIR(
            goal: "Refactor uploadChunk",
            constraints: ["TEST_PASS"],
            acceptance: ["TEST_PASS"]
        )
        let content = PromptRenderer.render(
            ir, options: PromptRenderOptions(symbolMode: .off,
                                             expandsRecognisedConstraints: true)
        ).content
        // A distinctive fragment rather than the whole expansion: the lexical
        // compressor legitimately trims a word or two on its way into the prompt.
        #expect(content.components(separatedBy: "existing tests must still pass").count - 1 == 1)
    }

    /// Prose bullets that merely overlap are `PromptOptimizer`'s problem — it has
    /// the token-overlap machinery to judge them, and this does not.
    @Test("prose is left alone")
    func prosePassesThrough() {
        let out = compress(PromptIR(
            goal: "Ship it",
            constraints: ["Finish before the Friday demo"],
            acceptance: ["Finish before the Friday demo"]
        ))
        #expect(out.constraints.count == 1)
        #expect(out.acceptance.count == 1)
    }
}
