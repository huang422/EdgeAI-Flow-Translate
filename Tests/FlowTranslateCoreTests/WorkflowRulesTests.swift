import Foundation
import Testing
@testable import FlowTranslateCore

@Suite("Workflow rules")
struct WorkflowRulesTests {

    private var workflow: [PromptRule] { PromptStdlib.all.rules(in: .workflow) }

    @Test("the category ships the thirteen documented rules")
    func categoryIsComplete() {
        let symbols = Set(workflow.map(\.symbol))
        #expect(symbols == [
            "EXPLAIN_FIRST", "RESEARCH_FIRST", "WEB_SEARCH", "FULL_REVIEW",
            "REPORT_FAILURES", "ASK_WHEN_UNSURE", "NO_PARTIAL_WORK", "CITE_SOURCES",
            "LIMIT_DELEGATION", "ONE_RECOMMENDATION",
            "BE_CONCISE", "NO_PADDING", "FLAG_AND_CONTINUE",
        ])
    }

    /// The whole point of the category: a spoken Chinese request has to reach
    /// the rule, or the rule may as well not exist.
    @Test("each rule is reachable from both languages")
    func matchPhrasesAreBilingual() {
        for rule in workflow {
            let hasChinese = rule.match.contains { phrase in
                phrase.contains { TokenEstimator.isCJK($0) }
            }
            let hasEnglish = rule.match.contains { phrase in
                phrase.contains { $0.isASCII && $0.isLetter }
            }
            #expect(hasChinese, "\(rule.symbol) has no Chinese phrasing")
            #expect(hasEnglish, "\(rule.symbol) has no English phrasing")
        }
    }

    @Test("every rule is traceable")
    func everyRuleCitesASource() {
        for rule in workflow {
            #expect(!rule.source.trimmingCharacters(in: .whitespaces).isEmpty, "\(rule.symbol)")
        }
    }

    /// A counter-intuitive rule without a reason is just a longer command. The
    /// reason is the part the evidence says does the work.
    @Test("counter-intuitive rules carry a rationale")
    func counterIntuitiveRulesExplainThemselves() {
        for rule in PromptStdlib.all.rules where rule.counterIntuitive {
            let rationale = rule.rationale ?? ""
            #expect(!rationale.trimmingCharacters(in: .whitespaces).isEmpty, "\(rule.symbol)")
        }
    }

    @Test("the user's own phrasings resolve")
    func theRequestedPhrasingsResolve() {
        let book = PromptStdlib.all
        let expected: [(String, String)] = [
            ("先說明後再實作", "EXPLAIN_FIRST"),
            ("上網搜尋", "WEB_SEARCH"),
            ("全面檢查", "FULL_REVIEW"),
            ("先研究", "RESEARCH_FIRST"),
            ("explain before implementing", "EXPLAIN_FIRST"),
            ("search the web", "WEB_SEARCH"),
        ]
        for (phrase, symbol) in expected {
            #expect(SymbolCompressor.match(phrase, in: book) == symbol,
                    "\(phrase) did not resolve to \(symbol)")
        }
    }
}

/// What the constraint-encoding paper's finding actually implies: encoding is
/// irrelevant to compliance, so every rule compresses — and the *reason* is what
/// a counter-intuitive rule pays extra for, because that is the lever the
/// evidence supports.
@Suite("Counter-intuitive rules keep their reason")
struct CounterIntuitiveRenderingTests {

    private func render(_ ir: PromptIR, layout: PromptLayout = .claudeXML) -> String {
        PromptRenderer.render(
            ir,
            options: PromptRenderOptions(symbolMode: .symbolsAssumeRulebook,
                                         syncedSymbols: Set(PromptStdlib.all.symbols),
                                         layout: layout)
        ).content
    }

    @Test("a conventional rule still collapses to its symbol")
    func conventionalRulesCompress() {
        let ir = PromptIR(goal: "Add retry", constraints: ["Do not add new dependencies"])
        let content = render(ir)
        #expect(content.contains("NO_DEPS"))
    }

    /// The symbol *and* the reason, at the mode where the rulebook resolves the
    /// symbol. Spelling the rule out as well bought nothing the encoding study
    /// could measure and cost four times the tokens.
    /// The prompt carries the symbol alone; the reason is fixed content and
    /// lives in the rules file the project loads once per session.
    @Test("a counter-intuitive rule compresses to a bare symbol")
    func counterIntuitiveRulesCompress() {
        let ir = PromptIR(goal: "Refactor the uploader",
                          constraints: ["explain before implementing"])
        let content = render(ir)
        #expect(content.contains("EXPLAIN_FIRST"))
        #expect(!content.contains("unrequested edit"), "\(content)")
        // The long form it replaced is gone too.
        #expect(!content.lowercased().contains("approval"), "\(content)")
        // And the reason is where it belongs.
        let rules = PromptRenderer.renderRulebook(PromptStdlib.all, language: .english).content
        #expect(rules.contains("unrequested edit"), "rules file lost the reason")
    }

    /// Without a rulebook on disk the symbol is unresolvable, so the mode
    /// downgrades and the full wording comes back — with the reason still on it.
    @Test("with no rulebook synced it expands, reason included")
    func unsyncedProjectStillGetsTheReason() {
        let content = PromptRenderer.render(
            PromptIR(goal: "Refactor the uploader",
                     constraints: ["explain before implementing"]),
            options: PromptRenderOptions(symbolMode: .symbolsAssumeRulebook, syncedSymbols: [])
        ).content
        #expect(!content.contains("EXPLAIN_FIRST"))
        #expect(content.lowercased().contains("approval"), "\(content)")
        #expect(content.contains("unrequested edit"), "\(content)")
    }

    @Test("the reason is dropped for rules that do not need it")
    func rationaleIsNotPaidForEverywhere() {
        let rule = PromptStdlib.all.rule(for: "NO_DEPS")
        #expect(rule?.counterIntuitive == false)
        #expect(rule?.fullStatement(for: .claude) == rule?.expansion(for: .claude))
    }

    /// Claude gets the positive form where one exists; Codex keeps the short
    /// declarative its own guidance asks for.
    @Test("the agent decides which wording is used")
    func wordingFollowsTheAgent() {
        let rule = PromptRule(
            symbol: "TEST_RULE",
            description: "Do not leave stubs.",
            backends: [.claude: "Never leave stubs.", .codex: "No stubs."],
            source: "test",
            positiveForm: "Finish every function you start; never leave a stub."
        )
        #expect(rule.expansion(for: .claude) == "Finish every function you start; never leave a stub.")
        #expect(rule.expansion(for: .codex) == "No stubs.")
    }

    /// A positive form *replaces* the prohibition, so one that drops it deletes
    /// the rule rather than reframing it. Reported, and refused.
    @Test("a positive form that drops the prohibition is refused, not emitted")
    func lossyPositiveFormIsRefused() {
        let rule = PromptRule(
            symbol: "TEST_RULE",
            description: "Do not leave stubs.",
            backends: [.claude: "Never leave stubs.", .codex: "No stubs."],
            source: "test",
            positiveForm: "Finish every function you start."
        )
        #expect(!rule.positiveFormIssues().isEmpty)
        #expect(rule.expansion(for: .claude) == "Never leave stubs.")
        #expect(!rule.validationErrors().isEmpty)
    }

    /// The other half: an identifier the definition names has to survive the
    /// reframing. `KEEP_API` without the letters `API` is a vaguer rule, and the
    /// term is what a reader greps for.
    @Test("a positive form that drops a named identifier is refused")
    func positiveFormKeepsNamedTerms() {
        let rule = PromptRule(
            symbol: "KEEP_THING",
            description: "Never change the public API signature.",
            backends: [.claude: "Never change the public API signature."],
            source: "test",
            positiveForm: "Never change the public interface."
        )
        #expect(rule.positiveFormIssues().contains { $0.contains("API") })
    }
}

/// Code review is where LLMs fail on precision rather than recall, and the
/// consequences are now measurable outside any one project. These rules encode
/// what three independent sources agree raises precision.
@Suite("Code review rules")
struct ReviewRulesTests {

    private var review: [PromptRule] { PromptStdlib.all.rules(in: .review) }

    @Test("the category ships the six sourced rules")
    func categoryIsComplete() {
        #expect(Set(review.map(\.symbol)) == [
            "REPORT_ALL_THEN_FILTER", "CONCRETE_FAILURE", "NO_STYLE_NITS",
            "NO_PREEXISTING", "CITE_THE_RULE", "RANK_BY_SEVERITY",
        ])
    }

    @Test("each rule is reachable from both languages")
    func matchPhrasesAreBilingual() {
        for rule in review {
            #expect(rule.match.contains { $0.contains { TokenEstimator.isCJK($0) } }, "\(rule.symbol)")
            #expect(rule.match.contains { $0.contains { $0.isASCII && $0.isLetter } }, "\(rule.symbol)")
        }
    }

    @Test("every rule is traceable")
    func everyRuleCitesASource() {
        for rule in review {
            #expect(!rule.source.trimmingCharacters(in: .whitespaces).isEmpty, "\(rule.symbol)")
        }
    }

    /// The one that reads backwards: asking for fewer findings gets you worse
    /// findings, not fewer wrong ones. It must never be compressed to a bare
    /// symbol, because that is precisely the class the encoding study found is
    /// ignored regardless of format.
    @Test("the two-pass rule compresses, and keeps its reason")
    func twoPassRuleKeepsItsReason() {
        let rule = PromptStdlib.all.rule(for: "REPORT_ALL_THEN_FILTER")
        #expect(rule?.counterIntuitive == true)
        #expect(rule?.rationale?.isEmpty == false)

        let content = PromptRenderer.render(
            PromptIR(goal: "Review this PR", constraints: ["report everything then filter"]),
            options: .init(symbolMode: .symbolsAssumeRulebook,
                           syncedSymbols: Set(PromptStdlib.all.symbols))
        ).content
        #expect(content.contains("REPORT_ALL_THEN_FILTER"))
        // The symbol carries the instruction. The reason — the part the encoding
        // study says moves compliance — is in the rules file, stated once per
        // session instead of once per prompt.
        #expect(!content.contains("fewer issues, not fewer wrong ones"), "\(content)")
        let rules = PromptRenderer.renderRulebook(PromptStdlib.all, language: .english).content
        #expect(rules.contains("fewer issues, not fewer wrong ones"), "rules file lost it")
    }

    /// A review prompt built from these rules must not contain the instruction
    /// the sources say destroys recall.
    @Test("no rule tells the reviewer to pre-filter by severity")
    func noRuleAsksForHighSeverityOnly() {
        for rule in review {
            let text = (rule.description + " " + rule.expansion(for: .claude)).lowercased()
            #expect(!text.contains("only report high"), "\(rule.symbol)")
            #expect(!text.contains("be conservative"), "\(rule.symbol)")
        }
    }
}

/// Anthropic's guidance is that showing the wanted behaviour beats forbidding
/// the unwanted one. The field for it existed and nothing used it, so the
/// mechanism was documented, wired into the renderer, and dead.
@Suite("Positive framing")
struct PositiveFormTests {

    @Test("prohibition-shaped rules carry a positive form")
    func prohibitionsHaveAPositiveForm() {
        let missing = PromptStdlib.all.rules.filter { rule in
            (rule.positiveForm ?? "").isEmpty && rule.symbol.hasPrefix("NO_")
                // These two are genuinely prohibitions: there is no useful
                // positive way to say "never force-push a shared branch", and
                // inventing one would soften the only thing they say.
                && !["NO_FORCE_PUSH", "NO_AI_ATTRIBUTION"].contains(rule.symbol)
        }
        #expect(missing.isEmpty, "no positive form: \(missing.map(\.symbol))")
    }

    /// Claude takes the positive form; Codex keeps the terse declarative its own
    /// guidance asks for. A single global rewrite would have served neither.
    @Test("the positive form is Claude's, not everyone's")
    func positiveFormIsPerAgent() {
        for rule in PromptStdlib.all.rules where (rule.positiveForm ?? "").isEmpty == false {
            #expect(rule.expansion(for: .claude) == rule.positiveForm, "\(rule.symbol)")
            #expect(rule.expansion(for: .codex) != rule.positiveForm, "\(rule.symbol)")
        }
    }
}

/// Conformance to Anthropic's published Opus 5 prompting guidance, item by item.
///
/// Written as a checklist rather than prose because "we follow the guidance" is
/// the kind of claim that quietly stops being true. Each case names the section
/// it comes from; if the guide changes, the failing test says which part.
@Suite("Opus 5 guidance conformance")
struct OpusFiveConformanceTests {

    private var book: PromptRulebook { PromptStdlib.all }

    private func rule(_ symbol: String) -> PromptRule? { book.rule(for: symbol) }

    @Test("Code review — report everything, filter in a separate pass")
    func codeReviewGuidance() {
        #expect(rule("REPORT_ALL_THEN_FILTER") != nil)
        // The guide's specific warning: a prompt asking for high-severity only
        // gets fewer findings, not fewer wrong ones.
        for r in book.rules(in: .review) {
            #expect(!r.expansion(for: .claude).lowercased().contains("only report high"))
        }
    }

    @Test("Response length — asked for explicitly, since effort does not control it")
    func verbosityGuidance() {
        #expect(rule("BE_CONCISE") != nil)
    }

    @Test("Written deliverable length — no filler, summaries or boilerplate")
    func deliverableLengthGuidance() {
        let expansion = rule("NO_PADDING")?.expansion(for: .claude) ?? ""
        #expect(expansion.contains("filler"))
        #expect(expansion.contains("boilerplate"))
    }

    @Test("Task scope — say so in a sentence and continue as asked")
    func scopeGuidance() {
        #expect(rule("FLAG_AND_CONTINUE") != nil)
        #expect(rule("MIN_DIFF") != nil)
        #expect(rule("NO_REFACTOR") != nil)
    }

    @Test("Subagents — delegate only large, genuinely independent work")
    func delegationGuidance() {
        let expansion = rule("LIMIT_DELEGATION")?.expansion(for: .claude).lowercased() ?? ""
        #expect(expansion.contains("independent"))
        // The guide's third clause: subagents are not for checking your own
        // work. Phrased positively here, so match the idea rather than the verb.
        #expect(expansion.contains("subagent"))
    }

    /// The guide says these instructions *cause* the behaviour they try to
    /// prevent, so the linter strips them from the user's own wording. This
    /// checks the rulebook never reintroduces them.
    @Test("no rule asks for self-verification or step-by-step thinking")
    func noOverVerification() {
        for r in book.rules {
            let text = (r.description + " " + r.expansion(for: .claude)).lowercased()
            #expect(!text.contains("double-check"), "\(r.symbol)")
            #expect(!text.contains("think step by step"), "\(r.symbol)")
            #expect(!text.contains("re-verify"), "\(r.symbol)")
        }
    }

    /// Explicitly warned against: it increases internal-tag leakage.
    @Test("no rule instructs the model not to think")
    func noAntiThinkingRule() {
        for r in book.rules {
            let text = (r.description + " " + r.expansion(for: .claude)).lowercased()
            #expect(!text.contains("do not think"), "\(r.symbol)")
            #expect(!text.contains("without reasoning"), "\(r.symbol)")
        }
    }

    /// A positive form replaces the backend wording, so it must carry the same
    /// instructions. Shorter is only better when nothing was lost.
    @Test("a positive form never drops what the prohibition said")
    func positiveFormKeepsTheContent() {
        let checks: [(String, [String])] = [
            ("LIMIT_DELEGATION", ["independent", "subagent"]),
            ("NO_PADDING", ["filler", "boilerplate"]),
            ("NO_SECRETS_IN_CODE", ["environment"]),
        ]
        for (symbol, required) in checks {
            let text = (rule(symbol)?.expansion(for: .claude) ?? "").lowercased()
            for term in required {
                #expect(text.contains(term), "\(symbol) lost \"\(term)\"")
            }
        }
    }

    /// The systemic version of the check above, so a new rule cannot ship a
    /// positive form that silently deletes its own constraint.
    ///
    /// The hand-written list caught three rules. This catches all of them, and
    /// found fifteen: every `NO_*` rule in the library had been reframed into a
    /// sentence that no longer forbade anything, which is what a live eval run
    /// reported as `NEGATION LOST — meaning inverted` on the two most ordinary
    /// requests in the corpus.
    @Test("every positive form in the library conforms")
    func libraryPositiveFormsConform() {
        let issues = book.rules.flatMap { $0.positiveFormIssues() }
        #expect(issues.isEmpty, "\(issues)")
    }

    /// The failure that started it: a prohibition the user actually spoke has to
    /// survive into the rendered prompt, in the mode most users are in.
    @Test("an expanded constraint still forbids what the request forbade")
    func expandedConstraintStillForbids() {
        for symbol in ["NO_DEPS", "KEEP_API", "NO_REFACTOR", "NO_SECRETS_IN_CODE"] {
            let text = rule(symbol)?.expansion(for: .claude) ?? ""
            #expect(SymbolCompressor.isNegated(text), "\(symbol): \(text)")
        }
        // And the identifier the request named comes back with it.
        #expect(rule("KEEP_API")?.expansion(for: .claude).contains("API") == true)
    }

    /// Positive framing beats prohibition — the guide's own words.
    @Test("prohibition-shaped rules offer Claude a positive form")
    func positiveFraming() {
        let bare = book.rules.filter {
            $0.symbol.hasPrefix("NO_") && ($0.positiveForm ?? "").isEmpty
        }
        #expect(bare.map(\.symbol).allSatisfy { ["NO_FORCE_PUSH", "NO_AI_ATTRIBUTION"].contains($0) })
    }
}
