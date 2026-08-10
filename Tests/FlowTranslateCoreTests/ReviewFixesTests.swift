import Foundation
import Testing
@testable import FlowTranslateCore

/// Regressions from a full review of the working tree. Each of these was
/// invisible to the existing suite and to reading the output.
@Suite("Review fixes")
struct ReviewFixesTests {

    /// Chinese has no word boundaries, so a one-character prefix cuts inside
    /// real words. The compressor's own filler list documents this rule; the
    /// optimizer's hedge list broke it.
    @Test("a bare 請 no longer cuts inside a word")
    func hedgeStrippingKeepsWholeWords() {
        #expect(PromptOptimizer.stripLeadingHedges("請求重試三次") == "請求重試三次")
        #expect(PromptOptimizer.stripLeadingHedges("請假流程要保留") == "請假流程要保留")
        // Multi-character hedges still go.
        #expect(PromptOptimizer.stripLeadingHedges("請你幫我加上重試") == "加上重試")
        #expect(PromptOptimizer.stripLeadingHedges("麻煩你加上重試") == "加上重試")
    }

    /// The goal is the most load-bearing field in the IR and was the only one
    /// the linter never looked at.
    @Test("the goal is linted like every other field")
    func goalIsLinted() {
        let ir = PromptIR(goal: "CRITICAL: think step by step and rewrite the uploader")
        let findings = PromptOptimizer.lint(ir)
        #expect(!findings.isEmpty, "the goal produced no findings")

        let fixed = PromptOptimizer.autoFix(ir).ir
        #expect(!fixed.goal.contains("CRITICAL"))
        #expect(!fixed.goal.lowercased().contains("step by step"))
        #expect(fixed.goal.lowercased().contains("uploader"))
    }

    /// `mm` is a hesitation sound and a unit. The unit loses.
    @Test("filler removal never eats a measurement")
    func unitsSurviveFillerRemoval() {
        let cleaned = SpokenNoiseCleaner().cleanup(
            "set the inset to 8 mm and the gap to 4 mm", origin: .speech
        )
        #expect(cleaned.contains("8 mm"))
        #expect(cleaned.contains("4 mm"))
        // Real hesitation still goes.
        #expect(!SpokenNoiseCleaner().cleanup("um add a retry", origin: .speech).contains("um "))
    }

    /// `"in terms of" → "re:"` turned a constraint into a subject line, at the
    /// level documented as meaning-preserving.
    @Test("no abbreviation rewrites a preposition into a gloss")
    func abbreviationsDoNotChangeMeaning() {
        let careful = LexicalCompressor.compress(
            "In terms of latency, do not exceed 200 ms",
            level: .careful, profile: .balanced, language: .english
        )
        #expect(!careful.lowercased().contains("re:"))
        #expect(careful.contains("200"))
    }

    /// A half-cached comparison must not mix an exact end with an estimated one:
    /// the ratio would be partly an artifact of the method.
    @Test("a comparison never mixes counters")
    func comparisonsNeverMixCounters() {
        struct HalfCounter: TokenCounting {
            func count(_ text: String) -> Int? { text == "before" ? 999 : nil }
        }
        let comparison = TokenMeter(counter: HalfCounter())
            .compare(before: "before", after: "after")
        #expect(comparison.source == .heuristic)
        // The exact 999 must not survive into a heuristic pair.
        #expect(comparison.before != 999)
    }

    /// The stdlib is read repeatedly by the settings pane; rebuilding it gave
    /// every rule a new identity each time.
    @Test("rule identity is stable across reads")
    func ruleIdentityIsStable() {
        let first = PromptStdlib.all.rules.map(\.id)
        let second = PromptStdlib.all.rules.map(\.id)
        #expect(first == second)
    }
}

/// One pass over a batch of findings is not enough: applying the first changes
/// the text the rest were matched against.
@Suite("Auto-fix reaches a fixed point")
struct AutoFixTests {

    @Test("stacked problems in one string are all fixed")
    func stackedProblemsAreAllFixed() {
        let ir = PromptIR(
            goal: "CRITICAL: think step by step and rewrite the uploader",
            constraints: ["IMPORTANT: double-check your answer before replying"]
        )
        let (fixed, remaining) = PromptOptimizer.autoFix(ir)

        #expect(!fixed.goal.contains("CRITICAL"))
        #expect(!fixed.goal.lowercased().contains("step by step"))
        #expect(fixed.goal.lowercased().contains("uploader"))
        #expect(!remaining.contains { $0.isAutoFixable })
    }

    /// The goal must survive being cleaned. A prompt with no task at all is
    /// worse than one with a badly worded task, because only the second is
    /// visible to the person who can fix it.
    @Test("cleaning never empties the goal")
    func goalIsNeverEmptied() {
        for goal in ["think step by step", "double-check your answer",
                     "CRITICAL: think step by step", "Add retry to the uploader"] {
            let fixed = PromptOptimizer.autoFix(PromptIR(goal: goal)).ir
            #expect(!fixed.goal.isEmpty, "\(goal) was emptied")
        }
    }

    /// "Unchanged" excludes the scope boundary, which the linter adds on
    /// purpose: recent models expand scope unless it is bounded, and that is the
    /// one fix that inserts rather than removes.
    @Test("a clean prompt keeps its wording and gains only a scope boundary")
    func cleanPromptIsUntouchedApartFromScope() {
        let ir = PromptIR(
            goal: "Add retry to the uploader",
            constraints: ["NO_DEPS"],
            scopeExclusions: ["Do not touch the parser"]
        )
        let (fixed, remaining) = PromptOptimizer.autoFix(ir)
        #expect(fixed == ir)
        #expect(remaining.filter(\.isAutoFixable).isEmpty)
    }

    /// And when no boundary was given, exactly one is added — once, not on
    /// every pass of the fixed-point loop.
    @Test("the scope boundary is added once")
    func scopeBoundaryIsAddedOnce() {
        let ir = PromptIR(goal: "Add retry to the uploader", constraints: ["NO_DEPS"])
        let fixed = PromptOptimizer.autoFix(ir).ir
        #expect(fixed.scopeExclusions.count == 1)
        #expect(PromptOptimizer.autoFix(fixed).ir.scopeExclusions.count == 1)
    }
}

/// `self?.method() ?? default` where the method itself returns an optional.
///
/// This shape reported every success as a failure: optional chaining produces
/// `String??`, and `??` collapses both levels, so a method returning nil for
/// "no error" had that nil replaced by the failure string. The prompt features
/// reported "model unavailable" on every successful load because of it.
@Suite("Optional collapse")
struct OptionalCollapseTests {

    private final class Owner {
        var fails = false
        func ensureReady() async -> String? { fails ? "failed" : nil }
    }

    @Test("the collapsing shape turns success into failure")
    func theBrokenShape() async {
        let owner: Owner? = Owner()
        let broken: () async -> String? = { [weak o = owner] in
            await o?.ensureReady() ?? "cancelled"
        }
        // Success, and yet a message comes back.
        #expect(await broken() == "cancelled")
    }

    @Test("separating the two cases reports success as success")
    func theFixedShape() async {
        let owner: Owner? = Owner()
        let fixed: () async -> String? = { [weak o = owner] in
            guard let o else { return "cancelled" }
            return await o.ensureReady()
        }
        #expect(await fixed() == nil)

        owner?.fails = true
        #expect(await fixed() == "failed")
    }
}

/// A switched-off rule category must not exist for the project at all.
///
/// The toggle used to apply at sync time only, so the model was still offered
/// every symbol and the compressor could still emit one — which then failed to
/// resolve, and `effectiveMode` downgrades on *any* unresolved symbol. Turning
/// off one category therefore disabled symbols for the whole prompt.
@Suite("Rule category scope")
struct RuleCategoryScopeTests {

    @Test("filtering removes the category from the book entirely")
    func filteringIsComplete() {
        let narrowed = PromptStdlib.all.filtered(to: [.coding, .testing])
        #expect(narrowed.rules(in: .security).isEmpty)
        #expect(!narrowed.symbols.contains("NO_SECRETS_IN_CODE"))
        #expect(narrowed.symbols.contains("NO_DEPS"))
    }

    /// With the category gone, its constraint is written out rather than
    /// compressed into a symbol nothing will define.
    @Test("a constraint from a switched-off category keeps its sentence")
    func switchedOffCategoriesAreNotCompressed() {
        let narrowed = PromptStdlib.all.filtered(to: [.coding])
        let ir = PromptIR(goal: "Store the key", constraints: ["Never commit secrets to the repo"])
        let result = SymbolCompressor.compress(ir, rulebook: narrowed)
        #expect(result.usedSymbols.isEmpty)
        #expect(result.ir.constraints == ["Never commit secrets to the repo"])
    }

    /// And the categories still enabled keep working — narrowing must not be
    /// all-or-nothing.
    @Test("enabled categories still compress")
    func enabledCategoriesStillWork() {
        let narrowed = PromptStdlib.all.filtered(to: [.coding])
        let result = SymbolCompressor.compress(
            PromptIR(goal: "x", constraints: ["Do not add new dependencies"]), rulebook: narrowed
        )
        #expect(result.usedSymbols == ["NO_DEPS"])
    }
}
