import Foundation
import Testing
@testable import FlowTranslateCore

/// The matcher against sentences people actually dictate.
///
/// `SymbolCoverageTests` checks that every *listed* phrasing resolves to its own
/// rule, which is close to circular — it can only catch a phrasing so short the
/// matcher cannot see it. This measures the thing that matters: does a sentence
/// nobody wrote into the rulebook reach the right symbol?
///
/// It found two classes of failure. Sentences that reached nothing ("上網搜尋"
/// variants that were not the one listed phrasing), and — worse — sentences that
/// reached the *wrong* rule, decided by nothing more than which rule the stdlib
/// declares first.
@Suite struct SymbolMatchAccuracyTests {

    private func symbol(for sentence: String) -> String? {
        let ir = PromptIR(goal: "do the work", constraints: [sentence])
        let compressed = SymbolCompressor.compress(
            ir, rulebook: PromptStdlib.all, backend: .claude, language: .english
        )
        guard let first = compressed.ir.constraints.first else { return nil }
        return SymbolCompressor.leadingSymbol(of: first)
            ?? (PromptStdlib.all.rule(for: first) != nil ? first : nil)
    }

    /// Sentences and the symbol each must reach. Chinese and English, and
    /// deliberately not copied from any rule's `match` list.
    static let corpus: [(String, String)] = [
        ("先上網搜尋目前最佳實作方式和策略", "WEB_SEARCH"),
        ("search online for the current best practice", "WEB_SEARCH"),
        ("look it up on the web first", "WEB_SEARCH"),
        ("先研究一下再動手", "RESEARCH_FIRST"),
        ("動手前先跟我說你要怎麼做", "EXPLAIN_FIRST"),
        ("不要自己亂猜，不確定就問我", "ASK_WHEN_UNSURE"),
        ("ask me if anything is unclear", "ASK_WHEN_UNSURE"),
        ("測試不要跳過", "NO_SKIP_TESTS"),
        ("不要加新的第三方套件", "NO_DEPS"),
        ("don't add any new dependencies", "NO_DEPS"),
        ("改動範圍越小越好", "MIN_DIFF"),
        ("keep the change as small as possible", "MIN_DIFF"),
        ("全部問題都先列出來再篩選", "REPORT_ALL_THEN_FILTER"),
        ("report everything you find, then filter", "REPORT_ALL_THEN_FILTER"),
        ("回答簡短一點", "BE_CONCISE"),
        ("失敗的話要老實告訴我", "REPORT_FAILURES"),
        ("要引用出處", "CITE_SOURCES"),
        ("cite your sources", "CITE_SOURCES"),
        ("不要動 public API", "KEEP_API"),
        ("commit message 要用 conventional commits", "CONVENTIONAL_COMMITS"),
        ("explain your plan before you start", "EXPLAIN_FIRST"),
        ("no stubs or TODOs", "NO_PARTIAL_WORK"),
        ("run the tests and tell me the result", "TEST_PASS"),
    ]

    @Test("dictated sentences reach the right symbol", arguments: corpus)
    func realisticSentenceResolves(_ sentence: String, _ expected: String) {
        #expect(symbol(for: sentence) == expected, "\(sentence)")
    }

    /// The failure that must never happen, stated separately from the coverage
    /// above: a sentence resolving to a rule it does not state puts a constraint
    /// in the prompt that the user never asked for. Missing the compression is
    /// the acceptable outcome; the wrong symbol is not.
    @Test("an ambiguous sentence compresses to nothing rather than to a guess")
    func ambiguityIsNotGuessed() {
        // Names both SOLVE_DONT_DEFER ("不要留 TODO") and NO_PARTIAL_WORK
        // ("不要留半成品") exactly, and scored 1.00 against each. It used to
        // resolve to whichever came first in the stdlib.
        #expect(symbol(for: "不要留 TODO 或半成品") == nil)
    }

    /// The counter-intuitive rules were exempt from compression entirely, which
    /// is why "上網搜尋" never came back as a symbol however often it was asked
    /// for. They compress to a bare symbol like every other rule now — the
    /// reason lives in the rules file, not in each prompt.
    @Test("a counter-intuitive rule compresses to a bare symbol")
    func counterIntuitiveCompresses() {
        let ir = PromptIR(goal: "改善壓縮率", constraints: ["先上網搜尋最佳做法"])
        let compressed = SymbolCompressor.compress(
            ir, rulebook: PromptStdlib.all, backend: .claude, language: .english
        )
        #expect(compressed.usedSymbols == ["WEB_SEARCH"])
        #expect(compressed.ir.constraints == ["WEB_SEARCH"])
    }
}

/// Where a directive has to be for the compressor to see it.
///
/// The second reason "上網搜尋" never came back as a symbol, independent of the
/// rulebook being stale: only `constraints`, `out_of_scope` and `done_when` are
/// ever rewritten, and "先上網搜尋目前最佳實作方式" is phrased as a step — so the
/// compiler files it under `steps`, where no rulebook change could ever reach it.
@Suite struct WorkflowHoistTests {

    private func render(_ ir: PromptIR) -> String {
        PromptRenderer.render(ir, options: .init(
            kind: .prompt, language: .english, symbolMode: .symbolsAssumeRulebook,
            rulebook: PromptStdlib.all, syncedSymbols: Set(PromptStdlib.all.symbols)
        )).content
    }

    @Test("a workflow directive filed as a step still compresses")
    func aStepIsHoisted() {
        let ir = PromptIR(goal: "改善壓縮率", steps: ["先上網搜尋目前最佳實作方式", "再修改程式"])
        let content = render(ir)
        #expect(content.contains("WEB_SEARCH"), "\(content)")
        // The real work stays a step.
        #expect(content.contains("再修改程式"), "\(content)")
    }

    @Test("a workflow directive filed as context still compresses")
    func contextIsHoisted() {
        let ir = PromptIR(goal: "改善壓縮率", context: ["先上網搜尋目前最佳實作方式"])
        #expect(render(ir).contains("WEB_SEARCH"))
    }

    @Test("a constraint keeps working as before")
    func aConstraintStillCompresses() {
        let ir = PromptIR(goal: "改善壓縮率", constraints: ["先上網搜尋目前最佳實作方式"])
        #expect(render(ir).contains("WEB_SEARCH"))
    }

    /// Real work is not a constraint, whatever category it touches.
    @Test("an ordinary step is left alone")
    func anOrdinaryStepStays() {
        let ir = PromptIR(goal: "改善壓縮率", steps: ["把重試機制加到 Sources/Uploader.swift"])
        let compressed = SymbolCompressor.compress(
            ir, rulebook: PromptStdlib.all, backend: .claude, language: .english
        )
        #expect(compressed.ir.steps == ["把重試機制加到 Sources/Uploader.swift"])
        #expect(compressed.ir.constraints.isEmpty)
    }

    /// A step that names something the symbol cannot name keeps its detail.
    @Test("a scoped step is not hoisted")
    func aScopedStepStays() {
        let ir = PromptIR(goal: "審查這個 PR", steps: ["上網搜尋 URLSession 的重試最佳做法"])
        let compressed = SymbolCompressor.compress(
            ir, rulebook: PromptStdlib.all, backend: .claude, language: .english
        )
        #expect(compressed.ir.steps.first?.contains("URLSession") == true)
    }

    /// Only "how to work" rules move: a testing or security rule can genuinely be
    /// a step of the work.
    @Test("a non-workflow rule stays a step")
    func nonWorkflowRulesStay() {
        let ir = PromptIR(goal: "準備發版", steps: ["測試要過"])
        let compressed = SymbolCompressor.compress(
            ir, rulebook: PromptStdlib.all, backend: .claude, language: .english
        )
        #expect(compressed.ir.steps == ["測試要過"])
    }

    /// Hoisting the same directive twice must not print it twice.
    @Test("a directive already stated as a constraint is not duplicated")
    func noDuplicates() {
        let ir = PromptIR(
            goal: "改善壓縮率",
            steps: ["先上網搜尋目前最佳實作方式"],
            constraints: ["先上網搜尋目前最佳實作方式"]
        )
        let content = render(ir)
        #expect(content.components(separatedBy: "WEB_SEARCH").count - 1 == 1, "\(content)")
    }
}

/// Rule wording follows the prompt's language — including the reason.
///
/// The eleven counter-intuitive rules used to be spelled out in full, in their
/// `zhHant` wording. Compressing them to `SYMBOL — reason` was a token win that
/// quietly introduced English into every Chinese prompt carrying one, because
/// `rationale` was the only piece of rule wording with no Chinese form.
@Suite struct ChineseRationaleTests {

    /// Enforced for the whole rulebook, not just the rules that exist today.
    @Test func everyRationaleHasATraditionalChineseForm() {
        let missing = PromptStdlib.all.rules
            .filter { $0.rationale != nil && $0.rationaleZhHant == nil }
            .map(\.symbol)
        #expect(missing.isEmpty, "\(missing)")
    }

    /// And the validator says so, so a rule added without one fails in the editor
    /// rather than in a prompt.
    @Test func aMissingChineseRationaleIsAValidationError() {
        var rule = PromptStdlib.all.rule(for: "WEB_SEARCH")!
        rule.rationaleZhHant = nil
        #expect(!PromptRulebook(rules: [rule]).validationErrors().isEmpty)
    }

    @Test func theBundledRulebookIsStillValid() {
        #expect(PromptStdlib.all.validationErrors() == [])
    }

    private func render(_ ir: PromptIR, _ language: PromptOutputLanguage) -> String {
        PromptRenderer.render(ir, options: .init(
            kind: .prompt, language: language, symbolMode: .symbolsAssumeRulebook,
            rulebook: PromptStdlib.all, syncedSymbols: Set(PromptStdlib.all.symbols)
        )).content
    }

    /// A synced project gets the bare symbol — the reason lives in the rules
    /// file, which the project loads once per session rather than once per
    /// prompt. Three tokens instead of twenty-eight, and nothing is lost.
    @Test("a synced prompt carries the bare symbol, not the reason")
    func syncedPromptIsBare() {
        let ir = PromptIR(goal: "改善壓縮率", constraints: ["先上網搜尋目前最佳實作方式"])
        let content = render(ir, .traditionalChinese)
        #expect(content.contains("WEB_SEARCH"), "\(content)")
        #expect(!content.contains("訓練資料"), "\(content)")
        #expect(!content.contains("training data"), "\(content)")
    }

    /// …and the rules file it was synced from carries both, in the language the
    /// file was written in.
    @Test func theRulesFileCarriesTheReason() {
        let chinese = PromptRenderer.renderRulebook(
            PromptStdlib.all, language: .traditionalChinese
        ).content
        #expect(chinese.contains("WEB_SEARCH"), "missing symbol")
        #expect(chinese.contains("訓練資料"), "missing Chinese reason")
        #expect(!chinese.contains("training data"), "English reason leaked")

        let english = PromptRenderer.renderRulebook(PromptStdlib.all, language: .english).content
        #expect(english.contains("training data"), "missing English reason")
        #expect(!english.contains("訓練資料"), "Chinese reason leaked")
    }

    /// Every counter-intuitive rule, in one sweep, so this cannot be right for
    /// `WEB_SEARCH` and wrong for the other ten.
    @Test func everyReasonReachesTheRulesFileInBothLanguages() {
        let chinese = PromptRenderer.renderRulebook(
            PromptStdlib.all, language: .traditionalChinese
        ).content
        let english = PromptRenderer.renderRulebook(PromptStdlib.all, language: .english).content
        for rule in PromptStdlib.all.rules where rule.counterIntuitive {
            if let reason = rule.rationaleZhHant {
                #expect(chinese.contains(reason), "\(rule.symbol) zh")
            }
            if let reason = rule.rationale {
                #expect(english.contains(reason), "\(rule.symbol) en")
                #expect(!chinese.contains(reason), "\(rule.symbol) leaked English into zh")
            }
        }
    }

    /// With no synced file the reason has nowhere else to live, so the legend
    /// spells it out — that mode exists for a reader who has never seen the
    /// rulebook.
    @Test func theLegendCarriesTheReason() {
        let legend = SymbolCompressor.legend(
            for: ["WEB_SEARCH"], rulebook: PromptStdlib.all, language: .english
        )
        #expect(legend.first?.contains("training data") == true, "\(legend)")
    }
}
