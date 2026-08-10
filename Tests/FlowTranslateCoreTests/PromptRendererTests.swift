import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct PromptRendererTests {

    private func sampleIR() -> PromptIR {
        PromptIR(
            taskType: .new,
            goal: "Add retry with backoff to the uploader",
            context: ["The uploader currently fails on transient 5xx"],
            constraints: ["Do not add new third-party dependencies."],
            scopeExclusions: ["Do not touch the parser"],
            deliverables: ["Updated Uploader.swift", "A unit test for the retry path"],
            acceptance: ["All existing tests must still pass."],
            references: [PromptReference(path: "Sources/Uploader.swift")],
            suggestedTools: ["Read", "Edit"]
        )
    }

    // MARK: - Body layout

    @Test func sectionOrderIsFixed() {
        // Fixed order is not only readability: a stable prefix across prompts is
        // what prompt caching rewards.
        // `.full`, because the order under test includes `out_of_scope`, which
        // `compact` withholds — it carries what the tool inferred rather than
        // what the request said.
        let artifact = PromptRenderer.render(
            sampleIR(), options: .init(kind: .prompt, symbolMode: .off, detail: .full))
        let content = artifact.content

        func position(_ needle: String) -> Int {
            content.range(of: needle).map { content.distance(from: content.startIndex, to: $0.lowerBound) } ?? -1
        }
        #expect(content.hasPrefix("<task>"))
        #expect(position("<output>") < position("<constraints>"))
        #expect(position("<constraints>") < position("<out_of_scope>"))
        #expect(position("<out_of_scope>") < position("<done_when>"))
        #expect(position("<done_when>") < position("<files>"))
    }

    /// Each layout is the structure its own vendor documents. The test is that
    /// they are actually different and each is well-formed — not that one is
    /// cheaper, because cost is not why either was chosen.
    @Test func eachLayoutMatchesItsVendorConvention() {
        let ir = sampleIR()
        let claude = PromptRenderer.render(
            ir, options: .init(kind: .prompt, symbolMode: .off, layout: .claudeXML)).content
        let codex = PromptRenderer.render(
            ir, options: .init(kind: .prompt, symbolMode: .off, layout: .codexMarkdown)).content

        #expect(claude.contains("<task>"))
        #expect(claude.contains("</task>"))
        #expect(!claude.contains("## "))

        #expect(codex.contains("## Goal"))
        #expect(!codex.contains("<task>"))
    }

    /// Every tag the Claude layout opens must close. An unbalanced tag turns the
    /// rest of the prompt into the contents of a section.
    @Test func claudeXMLTagsAreBalanced() {
        let content = PromptRenderer.render(
            sampleIR(), options: .init(kind: .prompt, symbolMode: .off, layout: .claudeXML)
        ).content
        let opens = matches("<([a-z_]+)>", in: content)
        let closes = matches("</([a-z_]+)>", in: content)
        #expect(!opens.isEmpty)
        #expect(opens.sorted() == closes.sorted(), "\(content)")
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
    }

    /// Compression is one profile now, so the question is no longer "does a
    /// stronger profile shrink it" but "does compressing shrink it at all".
    @Test func compressionShrinksTheOutput() {
        let ir = sampleIR()
        func tokens(_ profile: CompressionProfile) -> Int {
            PromptRenderer.render(
                ir, options: .init(kind: .prompt, symbolMode: .off, compression: profile)
            ).estimatedTokens
        }
        #expect(tokens(.balanced) <= tokens(CompressionProfile()))
    }

    @Test func pathsSurviveCompression() {
        // A lemmatized path is a broken path.
        let content = PromptRenderer.render(
            sampleIR(), options: .init(kind: .prompt, symbolMode: .off, compression: .balanced)
        ).content
        #expect(content.contains("Sources/Uploader.swift"), "path damaged by compression")
    }

    @Test func emptySectionsAreOmitted() {
        let bare = PromptIR(goal: "Ship it")
        let content = PromptRenderer.render(bare, options: .init(kind: .prompt)).content
        #expect(content == "<task>Ship it</task>")
        #expect(content.contains("CONSTRAINTS") == false)
    }

    @Test func shortGoalsAreNotPrunedIntoNonsense() {
        // "Ship it" has exactly one stopword; removing it saves one token and
        // costs the object of the sentence.
        let content = PromptRenderer.render(
            PromptIR(goal: "Ship it"),
            options: .init(kind: .prompt, compression: .balanced)
        ).content
        #expect(content == "<task>Ship it</task>")
    }

    @Test func markdownHeadingsFollowTheOutputLanguage() {
        let chinese = PromptRenderer.render(
            sampleIR(),
            options: .init(kind: .prompt, language: .traditionalChinese, symbolMode: .off,
                           layout: .codexMarkdown, detail: .full)
        ).content
        #expect(chinese.contains("## 產出"))
        #expect(chinese.contains("## 不要做"))
        #expect(chinese.contains("## Output") == false)
    }

    @Test func claudeTagsStayEnglishEvenForChineseContent() {
        // Deliberate: tag names are structural keywords, they cost a third of
        // what their Chinese equivalents would, and Anthropic's guidance is to
        // use consistent descriptive names. Only the content is localized.
        let chineseIR = PromptIR(goal: "把上傳器加上重試機制", constraints: ["不要新增第三方套件"])
        let content = PromptRenderer.render(
            chineseIR, options: .init(kind: .prompt, language: .traditionalChinese, symbolMode: .off)
        ).content
        #expect(content.hasPrefix("<task>"))
        #expect(content.contains("<constraints>"))
        #expect(content.contains("把上傳器加上重試機制"))
        // The constraint comes back in the rulebook's Chinese wording rather
        // than the caller's — that substitution is what this mode is for.
        #expect(content.contains("第三方"))
    }

    @Test func symbolModesProduceTheExpectedOutput() {
        let ir = sampleIR()

        // Full sentences: the rulebook's own wording, no identifier to resolve.
        // `expandsRecognisedConstraints` is what asks for the rulebook's phrasing
        // in place of the caller's — `off` on its own keeps what the user wrote.
        let inline = PromptRenderer.render(ir, options: .init(
            kind: .prompt, symbolMode: .off, expandsRecognisedConstraints: true))
        // Claude gets the positive form of the rule, per Anthropic's guidance
        // that showing the wanted behaviour beats forbidding the unwanted one.
        #expect(inline.content.contains("already depends on"))
        #expect(inline.content.contains("NO_DEPS") == false)
        #expect(inline.usedSymbols.isEmpty)

        // Symbols: bare, and only once the project can resolve them.
        let symbols = PromptRenderer.render(
            ir,
            options: .init(kind: .prompt, symbolMode: .symbolsAssumeRulebook,
                           syncedSymbols: ["NO_DEPS", "TEST_PASS"])
        )
        #expect(symbols.content.contains("NO_DEPS"))
        #expect(symbols.usedSymbols.contains("NO_DEPS"))
        // No legend: the mode that appended one is gone, because emitting the
        // symbol AND its definition cost more than the sentence alone.
        #expect(!symbols.content.contains("NO_DEPS = "))
    }

    @Test func bareSymbolsOnlyWhenTheRulebookIsSynced() {
        let ir = sampleIR()

        // Not synced: the constraint is written out rather than emitted as a
        // symbol nothing defines — and without a legend, which would cost more
        // than the sentence it explains.
        let unsynced = PromptRenderer.render(
            ir, options: .init(kind: .prompt, symbolMode: .symbolsAssumeRulebook, syncedSymbols: [])
        )
        #expect(!unsynced.content.contains("NO_DEPS"))
        #expect(unsynced.content.contains("already depends on"))

        let synced = PromptRenderer.render(
            ir,
            options: .init(
                kind: .prompt,
                symbolMode: .symbolsAssumeRulebook,
                syncedSymbols: ["NO_DEPS", "TEST_PASS"]
            )
        )
        #expect(synced.content.contains("NO_DEPS"))
        #expect(synced.content.contains("NO_DEPS = ") == false)
    }

    @Test func symbolsAreCheaperThanTheirExpansions() {
        let ir = sampleIR()
        let expanded = PromptRenderer.render(ir, options: .init(kind: .prompt, symbolMode: .off))
        let symbolic = PromptRenderer.render(
            ir,
            options: .init(
                kind: .prompt, symbolMode: .symbolsAssumeRulebook, syncedSymbols: ["NO_DEPS", "TEST_PASS"]
            )
        )
        #expect(symbolic.estimatedTokens < expanded.estimatedTokens)
    }

    // MARK: - Skill backend

    @Test func skillFrontmatterMeetsAnthropicRequirements() {
        let artifact = PromptRenderer.render(sampleIR(), options: .init(kind: .skill))
        let lines = artifact.content.components(separatedBy: "\n")
        #expect(lines.first == "---")

        let name = lines.first { $0.hasPrefix("name: ") }.map { String($0.dropFirst(6)) }
        let description = lines.first { $0.hasPrefix("description: ") }.map { String($0.dropFirst(13)) }
        #expect(name != nil)
        #expect(description != nil)

        let nameValue = name ?? ""
        #expect(nameValue.count <= 64)
        #expect(nameValue.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" })
        #expect(nameValue.contains("claude") == false)
        #expect(nameValue.contains("anthropic") == false)

        let descriptionValue = description ?? ""
        #expect(descriptionValue.count <= 1024)
        #expect(descriptionValue.contains("\n") == false)
        // Must say when to use it — that pair is all Claude has when choosing
        // among many skills.
        #expect(descriptionValue.contains("Use when"))
    }

    @Test func skillGoesToTheConventionalPath() {
        let artifact = PromptRenderer.render(sampleIR(), options: .init(kind: .skill))
        #expect(artifact.relativePath?.hasPrefix(".claude/skills/") == true)
        #expect(artifact.relativePath?.hasSuffix("/SKILL.md") == true)
    }

    @Test func skillNameUsesGerundFormWhenTheVerbIsKnown() {
        let ir = PromptIR(goal: "Refactor the uploader")
        #expect(PromptRenderer.derivedName(from: ir).hasPrefix("refactoring"))
    }

    @Test func skillNameFallsBackWhenTheGoalHasNoLatinWords() {
        // A Chinese-only goal leaves nothing that satisfies the name charset;
        // emitting an empty `name` would make the skill invalid.
        let ir = PromptIR(goal: "把上傳器加上重試機制")
        #expect(PromptRenderer.derivedName(from: ir) == "composed-prompt")
    }

    @Test func skillNameStripsReservedWords() {
        let ir = PromptIR(goal: "Fix the claude integration bug")
        let name = PromptRenderer.derivedName(from: ir)
        #expect(name.contains("claude") == false)
        #expect(name.isEmpty == false)
    }

    // MARK: - Command backend

    @Test func commandCarriesADescriptionAndConventionalPath() {
        let artifact = PromptRenderer.render(sampleIR(), options: .init(kind: .command))
        #expect(artifact.content.hasPrefix("---\ndescription: "))
        #expect(artifact.relativePath?.hasPrefix(".claude/commands/") == true)
        #expect(artifact.relativePath?.hasSuffix(".md") == true)
    }

    @Test func nameOverrideIsSluggedNotTrusted() {
        let artifact = PromptRenderer.render(
            sampleIR(), options: .init(kind: .command, nameOverride: "My Fancy Name!")
        )
        #expect(artifact.relativePath == ".claude/commands/my-fancy-name.md")
    }

    // MARK: - Rules backend

    @Test func rulebookRendersToTheOfficialRulesPath() {
        let artifact = PromptRenderer.renderRulebook(PromptStdlib.all, language: .english)
        #expect(artifact.relativePath == ".claude/rules/flow-translate-symbols.md")
        #expect(artifact.content.contains("**NO_DEPS**"))
        #expect(artifact.usedSymbols.contains("TEST_PASS"))
    }

    @Test func rulebookSurvivesAWriteReadRoundTrip() {
        // Safety-critical: this pair decides whether bare symbols are safe to
        // emit. If reading ever stopped matching writing, `syncedSymbols` would
        // return nothing and the cheapest symbol mode would silently never
        // engage — a failure with no error to notice.
        let artifact = PromptRenderer.renderRulebook(PromptStdlib.all, language: .english)
        let recovered = PromptRenderer.parseSymbols(from: artifact.content)
        #expect(recovered == PromptStdlib.all.symbols)
    }

    @Test func roundTripSurvivesLocalizedExpansions() {
        let artifact = PromptRenderer.renderRulebook(PromptStdlib.all, language: .traditionalChinese)
        #expect(PromptRenderer.parseSymbols(from: artifact.content) == PromptStdlib.all.symbols)
    }

    @Test func parsingIgnoresBoldTextThatIsNotASymbol() {
        #expect(PromptRenderer.parseSymbols(from: "- **Important** note here").isEmpty)
        #expect(PromptRenderer.parseSymbols(from: "- **NO_DEPS** — text") == ["NO_DEPS"])
    }

    @Test func pathScopedRulesBecomeTheirOwnFileWithFrontmatter() {
        // Scoping is a token optimization: a scoped rule costs nothing on work
        // that never touches matching files.
        let book = PromptRulebook(rules: [
            PromptRule(symbol: "SWIFT_STYLE", description: "Use four-space indentation.",
                       source: "test", paths: ["**/*.swift"]),
        ])
        let artifact = PromptRenderer.renderRulebook(book, language: .english)
        let companion = artifact.companions.first
        #expect(companion?.relativePath == ".claude/rules/flow-translate-swift-style.md")
        #expect(companion?.content.contains("paths:") == true)
        #expect(companion?.content.contains("\"**/*.swift\"") == true)
    }
}

/// The output-language setting has to reach the output, not just the model.
///
/// Two halves have to agree: the compiler tells the model which language to
/// write the IR in, and the renderer expands every rulebook constraint in the
/// same language. If only the first were wired, a Chinese prompt would carry
/// English constraints; if only the second, the reverse.
@Suite("Output language wiring")
struct OutputLanguageTests {

    private func render(_ language: PromptOutputLanguage) -> String {
        PromptRenderer.render(
            PromptIR(
                goal: "Add retry to the uploader",
                constraints: ["Do not add new third-party dependencies"],
                acceptance: ["All existing tests must pass"]
            ),
            options: .init(language: language, symbolMode: .off,
                           expandsRecognisedConstraints: true)
        ).content
    }

    @Test("Chinese output expands the rules in Chinese")
    func chineseReachesTheConstraints() {
        let content = render(.traditionalChinese)
        #expect(content.contains("第三方"))
        #expect(content.contains("測試"))
        #expect(!content.contains("third-party"))
    }

    @Test("English output stays English")
    func englishStaysEnglish() {
        let content = render(.english)
        #expect(content.contains("already depends on"))
        #expect(!content.contains("第三方"))
    }

    /// The positive form is a Claude preference, not a global rewrite: Codex's
    /// own guidance asks for short declaratives, and "no new dependencies" is
    /// both shorter and the form that guidance wants.
    @Test("Codex keeps the terse prohibition")
    func codexKeepsTheProhibition() {
        let rule = PromptStdlib.all.rule(for: "NO_DEPS")
        #expect(rule?.expansion(for: .claude).contains("already depends on") == true)
        #expect(rule?.expansion(for: .codex).lowercased().contains("no new") == true)
    }

    /// An explicit choice must survive script detection. `resolved(for:)` exists
    /// Both options are explicit, so a selection is never overridden by the
    /// script of the text — picking Chinese for an English request has to mean
    /// Chinese.
    @Test("an explicit choice is not overridden by the text's own script")
    func explicitChoiceWins() {
        #expect(PromptOutputLanguage.traditionalChinese.resolved(for: "all English here")
                == .traditionalChinese)
        #expect(PromptOutputLanguage.english.resolved(for: "全部都是中文") == .english)
    }

    /// Settings saved when a third "follow the input" option existed must still
    /// decode — to English, the default and the cheaper of the two.
    @Test("a stored follow-input value decodes to English")
    func legacyFollowInputMigrates() throws {
        let decoded = try JSONDecoder().decode(
            PromptOutputLanguage.self, from: Data("\"auto\"".utf8)
        )
        #expect(decoded == .english)
    }

}

/// What a language change can and cannot do without another model call.
///
/// The setting reaches the rulebook expansions immediately, but the goal and
/// context are prose the model wrote — a re-render leaves them in whatever
/// language was selected when they were produced. Documented here because the
/// half-updated output reads as a broken switch, and the app's answer is to
/// recompile rather than to pretend a re-render is enough.
@Suite("Language change scope")
struct LanguageChangeTests {

    private let ir = PromptIR(
        goal: "Add exponential-backoff retry to the uploader",
        constraints: ["Do not add new third-party dependencies"]
    )

    private func render(_ language: PromptOutputLanguage) -> String {
        PromptRenderer.render(
            ir, options: .init(language: language, symbolMode: .off,
                               expandsRecognisedConstraints: true)
        ).content
    }

    @Test("rule expansions follow the language immediately")
    func expansionsFollowTheSetting() {
        #expect(render(.traditionalChinese).contains("第三方"))
        #expect(!render(.english).contains("第三方"))
    }

    /// The half a re-render cannot do. If this ever starts passing, the renderer
    /// has gained a translator and the recompile-on-change behaviour should go.
    @Test("model-written prose is not translated by re-rendering")
    func proseIsNotRetranslated() {
        #expect(render(.traditionalChinese).contains("Add exponential-backoff retry"))
    }
}

/// "No symbols appear in this prompt" has two causes with opposite advice:
/// nothing matched a rule, or something did and the project has no rulebook.
/// The UI nudge is only right about the second.
@Suite("Unresolved symbols")
struct UnresolvedSymbolsTests {

    private func render(_ ir: PromptIR, synced: Set<String> = []) -> PromptArtifact {
        PromptRenderer.render(ir, options: PromptRenderOptions(
            symbolMode: .symbolsAssumeRulebook, syncedSymbols: synced
        ))
    }

    @Test("a recognised constraint the project cannot define is reported")
    func reportsWhatSyncingWouldFix() {
        let ir = PromptIR(goal: "Add a retry", constraints: ["NO_DEPS"])
        #expect(render(ir).unresolvedSymbols == ["NO_DEPS"])
    }

    /// The case the old condition got wrong: a prompt whose constraints match no
    /// rule at all. Syncing changes nothing, so there is nothing to say.
    @Test("a constraint that matches no rule reports nothing to sync")
    func staysSilentWhenSyncingCannotHelp() {
        let ir = PromptIR(goal: "Add a retry", constraints: ["Ship before the demo on Friday"])
        #expect(render(ir).unresolvedSymbols.isEmpty)
    }

    @Test("a symbol the project already defines is not reported")
    func staysSilentOnceSynced() {
        let ir = PromptIR(goal: "Add a retry", constraints: ["NO_DEPS"])
        #expect(render(ir, synced: ["NO_DEPS"]).unresolvedSymbols.isEmpty)
        #expect(render(ir, synced: ["NO_DEPS"]).usedSymbols == ["NO_DEPS"])
    }

    @Test("modes that never emit bare symbols report nothing")
    func onlyAppliesToBareSymbolMode() {
        let ir = PromptIR(goal: "Add a retry", constraints: ["NO_DEPS"])
        for mode in [PromptSymbolMode.off, .off, .symbolsWithLegend] {
            let artifact = PromptRenderer.render(
                ir, options: PromptRenderOptions(symbolMode: mode)
            )
            #expect(artifact.unresolvedSymbols.isEmpty, "\(mode)")
        }
    }
}
