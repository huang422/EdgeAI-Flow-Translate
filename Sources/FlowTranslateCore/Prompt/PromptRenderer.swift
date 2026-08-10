import Foundation

/// Which agent the prompt is written for, and therefore how it is laid out.
///
/// Not a cosmetic choice: each option is the structure its vendor documents as
/// the one that works, and the two vendors document different structures.
///
/// An earlier `labelled` layout (`TASK:` / `CONSTRAINTS:`) was a token or two
/// cheaper per section than either of these. It was dropped because the saving
/// is small and unsourced, while both of these are what the people who trained
/// the models say to do.
public enum PromptLayout: String, Codable, Sendable, CaseIterable, Identifiable {
    /// XML tags — `<task>`, `<context>`, `<constraints>`.
    ///
    /// Anthropic's prompting guide: "XML tags help Claude parse complex prompts
    /// unambiguously, especially when your prompt mixes instructions, context,
    /// examples, and variable inputs", with the advice to use consistent,
    /// descriptive tag names.
    case claudeXML
    /// Markdown headings following OpenAI's four building blocks — goal,
    /// context, format, constraints — and their guidance to describe the result
    /// rather than the steps.
    ///
    /// Also what skills and slash commands need, since those are markdown
    /// documents in their own right.
    case codexMarkdown

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .claudeXML: return "Claude（XML 標籤）"
        case .codexMarkdown: return "Codex / AGENTS.md（Markdown）"
        }
    }

    /// Short form for a segmented control, where each option gets a fraction of
    /// the row and the full name is cut off.
    public var shortName: String {
        switch self {
        case .claudeXML: return "Claude"
        case .codexMarkdown: return "Codex"
        }
    }

    /// The rule wording to use with this layout.
    public var backend: RuleBackend {
        switch self {
        case .claudeXML: return .claude
        case .codexMarkdown: return .codex
        }
    }
}

/// Everything the renderer needs that is not in the IR itself.
public struct PromptRenderOptions: Sendable {
    public var kind: PromptArtifactKind
    public var language: PromptOutputLanguage
    public var symbolMode: PromptSymbolMode
    public var rulebook: PromptRulebook
    /// Symbols already present in the target project's `.claude/rules/`. Used
    /// to decide whether bare symbols are safe.
    public var syncedSymbols: Set<String>
    /// Overrides the derived skill/command name.
    public var nameOverride: String?
    /// How hard to compress. Applied per section, not per prompt.
    public var compression: CompressionProfile
    /// Which agent the prompt targets, and therefore whether it comes out as
    /// XML tags or Markdown headings. Skills and commands always render as
    /// Markdown regardless, being Markdown documents themselves.
    public var layout: PromptLayout
    /// How many of the sections to print. Sections the compiler inferred rather
    /// than heard are the first to go.
    public var detail: PromptDetailLevel
    /// Rewrite constraints the rulebook recognises into its own fuller wording,
    /// even in `off`.
    ///
    /// Not a user-facing mode — it is what the savings meter needs. "Symbols
    /// saved you N tokens" is a comparison against the constraints written out
    /// in full, so the baseline has to be that text, and `off` alone deliberately
    /// leaves the user's own sentences as they are.
    public var expandsRecognisedConstraints: Bool

    public init(
        kind: PromptArtifactKind = .prompt,
        language: PromptOutputLanguage = .english,
        symbolMode: PromptSymbolMode = .symbolsAssumeRulebook,
        rulebook: PromptRulebook = PromptStdlib.all,
        syncedSymbols: Set<String> = [],
        nameOverride: String? = nil,
        compression: CompressionProfile = .balanced,
        layout: PromptLayout = .claudeXML,
        detail: PromptDetailLevel = .compact,
        expandsRecognisedConstraints: Bool = false
    ) {
        self.kind = kind
        self.language = language
        self.symbolMode = symbolMode
        self.rulebook = rulebook
        self.syncedSymbols = syncedSymbols
        self.nameOverride = nameOverride
        self.compression = compression
        self.layout = layout
        self.detail = detail
        self.expandsRecognisedConstraints = expandsRecognisedConstraints
    }
}

/// The backend compiler: one IR in, one target-specific artifact out.
///
/// Kept deliberately separate from optimization so the same optimized IR can be
/// emitted as a clipboard prompt, an installed skill or a slash command
/// without any of them drifting apart.
public enum PromptRenderer {

    /// Anthropic's authoring guidance puts the practical ceiling for a SKILL.md
    /// body here; past it, content moves into `references/` so Claude loads
    /// only what a given task needs.
    static let maxSkillBodyLines = 500

    public static func render(_ ir: PromptIR, options: PromptRenderOptions) -> PromptArtifact {
        let language = options.language.resolved(for: ir.goal + " " + ir.allBullets.joined(separator: " "))

        // Skills and commands are markdown documents; XML section tags inside
        // one read as content rather than structure.
        let layout: PromptLayout = (options.kind == .skill || options.kind == .command)
            ? .codexMarkdown : options.layout
        // The layout *is* the agent choice, so it also selects which wording of
        // each rule gets emitted — Claude's fuller phrasing versus Codex's short
        // declaratives.
        let backend = layout.backend

        // Reduce to what will actually be printed BEFORE compressing.
        //
        // The other order was wrong in a way that showed up in three places at
        // once: `usedSymbols`, the legend and `effectiveMode` were all derived
        // from sections `renderBody` then dropped, so a symbol living only inside
        // a discarded `out_of_scope` could downgrade the whole prompt to the
        // written-out mode, put an entry in a legend for an identifier the prompt
        // never mentions, and make the UI advise syncing a rulebook to shorten
        // text that is not in the output. Compressing only the visible IR makes
        // all of them agree by construction.
        let visible = ir.visible(at: options.detail)
        let compressed = SymbolCompressor.compress(
            visible, rulebook: options.rulebook, backend: backend, language: language
        )
        let mode = SymbolCompressor.effectiveMode(
            requested: options.symbolMode,
            usedSymbols: compressed.usedSymbols,
            syncedSymbols: options.syncedSymbols
        )

        let body: PromptIR
        let symbols: [String]
        switch mode {
        case .off:
            // Which IR gets expanded is the whole difference between "keep my
            // wording" and "write the rules out", and both arrive here.
            //
            // Asked for directly, `off` expands the IR as it stands: a symbol
            // the model emitted is still resolved — a prompt must never ship an
            // identifier its reader cannot look up — but a sentence the user
            // wrote is left alone, which is what the mode promises.
            //
            // Reached by downgrade (bare symbols requested, nothing in the
            // project defines them), the request was for the rulebook's wording,
            // so the *compressed* IR is expanded and recognised constraints come
            // back in full. Losing that distinction was the one regression in
            // folding the old `expandInline` mode into this one.
            let wantsRulebookWording =
                options.symbolMode != .off || options.expandsRecognisedConstraints
            body = SymbolCompressor.expand(
                wantsRulebookWording ? compressed.ir : ir,
                rulebook: options.rulebook, language: language, backend: backend
            )
            symbols = []
        case .symbolsWithLegend, .symbolsAssumeRulebook:
            body = compressed.ir
            symbols = compressed.usedSymbols
        }

        // Which symbols the compressor found but the project cannot define. Only
        // meaningful when bare symbols were asked for and the mode was downgraded
        // because of it — that is the one situation where syncing a rulebook
        // changes the output.
        let unresolved = options.symbolMode.requiresSyncedRulebook
            ? compressed.usedSymbols.filter { !options.syncedSymbols.contains($0) }
            : []

        let legend = (mode == .symbolsWithLegend && !symbols.isEmpty)
            ? SymbolCompressor.legend(
                for: symbols, rulebook: options.rulebook, language: language, backend: backend
              )
            : []
        let prompt = renderBody(
            body, language: language, legend: legend,
            profile: options.compression, layout: layout
        )

        switch options.kind {
        case .prompt:
            return PromptArtifact(
                kind: .prompt, content: prompt,
                usedSymbols: symbols, unresolvedSymbols: unresolved
            )
        case .command:
            return renderCommand(
                body, prompt: prompt, options: options, language: language,
                symbols: symbols, unresolved: unresolved
            )
        case .skill:
            return renderSkill(
                body, prompt: prompt, options: options, language: language,
                symbols: symbols, unresolved: unresolved
            )
        case .rules:
            // `backend`, like every other kind. Omitting it fell back to the
            // `.claude` default, so a rulebook rendered for a Codex target came
            // out in Claude's fuller phrasing — the one thing the backend
            // parameter exists to decide.
            return renderRulebook(options.rulebook, language: language, backend: backend)
        }
    }

    // MARK: - Body

    /// Section order is fixed: goal, then what to produce, then the rules, then
    /// how "done" is checked. Beyond readability this keeps a stable prefix
    /// across prompts, which is what prompt caching rewards.
    static func renderBody(
        _ ir: PromptIR,
        language: PromptOutputLanguage,
        legend: [String],
        profile: CompressionProfile = .balanced,
        layout: PromptLayout = .claudeXML
    ) -> String {
        let titles = SectionTitles.for(language, layout: layout)

        // Compression level per section, not per prompt. The narrative can lose
        // half its words and still say the same thing; a constraint cannot lose
        // one, and a path cannot change at all.
        func squeeze(_ items: [String], _ level: CompressionLevel) -> [String] {
            PromptIR.normalize(items.map {
                LexicalCompressor.compress($0, level: level, profile: profile, language: language)
            })
        }

        var blocks: [String] = []

        // The question first, because it is what the reader has to deal with
        // before anything else — and it is `protected`, not `free`. The
        // compressor shortens prose without changing meaning, but on a question
        // it can prune the very word being asked about: "為何字幕會跳動" came out
        // no longer asking anything. It is one line either way.
        if ir.asksAQuestion {
            // Numbered when there is more than one, so an answer can be checked
            // against them one by one. A single question stays inline — a list
            // of one is just punctuation.
            let asked = ir.questions
            blocks.append(section(
                titles.question, asked.count > 1 ? numbered(asked) : asked,
                layout: layout, inlineSingle: true
            ))
        }

        let goal = LexicalCompressor.compress(
            ir.goal, level: .free, profile: profile, language: language
        )
        if !goal.isEmpty {
            blocks.append(taskSection(
                title: titles.task,
                goal: goal,
                steps: numbered(squeeze(ir.steps, .careful), goal: goal),
                layout: layout
            ))
        }

        // Anthropic's own wording for a request that should not be acted on,
        // from the prompting guide's "sample prompt for conservative action".
        //
        // Which of the two forms depends on whether there is also work to do, and
        // that distinction is the whole reason `question` and `goal` are separate
        // fields. A pure question must not be acted on at all. A request that
        // asks *and* instructs must be answered first and then carried out —
        // telling it not to act there would contradict the task tag directly
        // above.
        if ir.asksAQuestion {
            blocks.append(section(
                titles.answerFirst,
                [ir.isPureQuestion ? titles.answerOnlyBody : titles.answerThenActBody],
                layout: layout, inlineSingle: true
            ))
        }

        // No detail gating here. `PromptIR.visible(at:)` has already removed
        // whatever this level does not print, upstream of symbolic compression —
        // which is where it has to happen, since the symbols the prompt uses are
        // a function of the sections that survive. Gating a second time here
        // bought nothing (three of the six branches could never be false) and
        // hid the fact that the section list and the symbol list were computed
        // from two different IRs.
        append(&blocks, titles.context, squeeze(ir.context, .free), layout)
        append(&blocks, titles.deliverables, squeeze(ir.deliverables, .careful), layout)
        append(&blocks, titles.constraints, squeeze(ir.constraints, .careful), layout)
        append(&blocks, titles.exclusions, squeeze(ir.scopeExclusions, .careful), layout)
        append(&blocks, titles.acceptance, squeeze(ir.acceptance, .careful), layout)
        append(&blocks, titles.failureCases, squeeze(ir.failureCases, .careful), layout)

        if !ir.references.isEmpty {
            // Paths are `protected`: a lemmatized path is a broken path.
            let lines = ir.references.map { reference -> String in
                var line = "`\(reference.path)`"
                if reference.loadMode == .outOfScope { line += " — \(titles.outOfScopeNote)" }
                if let note = reference.note, !note.isEmpty { line += " — \(note)" }
                return line
            }
            append(&blocks, titles.references, lines, layout)
        }

        append(&blocks, titles.tools, ir.suggestedTools, layout)
        // The legend is never gated: it is what makes the symbols in the sections
        // above resolvable, so dropping it would leave identifiers nothing
        // defines — the exact failure `effectiveMode` exists to prevent.
        append(&blocks, titles.rules, legend, layout)

        return blocks.joined(separator: "\n\n")
    }

    /// Empty sections are never printed — a heading with nothing under it costs
    /// tokens and tells the model nothing.
    static func append(
        _ blocks: inout [String], _ title: String, _ items: [String], _ layout: PromptLayout
    ) {
        guard !items.isEmpty else { return }
        blocks.append(section(title, items, layout: layout, inlineSingle: true))
    }

    /// Number the work items, so a multi-part request reads as a checklist.
    ///
    /// Anthropic's prompting guide asks for this directly: "provide instructions
    /// as sequential steps using numbered lists or bullet points when the order
    /// or completeness of steps matters". Completeness is the point — the failure
    /// this addresses is the last requirement of a long request going missing,
    /// and a numbered list is the one shape where a missing item is visible.
    ///
    /// The numbers are baked into the strings rather than left to the bullet
    /// renderer, because `section` writes `- ` bullets everywhere else and one
    /// section rendering differently from the rest is what tag consistency is
    /// supposed to prevent.
    /// The task block: a one-line summary, then the ordered work under it.
    ///
    /// Its own function because the goal is not a list item. Running it through
    /// `section` alongside the steps bulleted it — `- Rewrite the renderer`
    /// followed by `1.`, `2.`, `3.` — which reads as a four-item list whose first
    /// entry is formatted differently, rather than as a summary and its steps.
    /// The blank line between them is what makes the summary a lead-in.
    static func taskSection(
        title: String, goal: String, steps: [String], layout: PromptLayout
    ) -> String {
        guard !steps.isEmpty else {
            return section(title, [goal], layout: layout, inlineSingle: true)
        }
        let body = ([goal, ""] + steps).joined(separator: "\n")
        switch layout {
        case .claudeXML: return "<\(title)>\n\(body)\n</\(title)>"
        case .codexMarkdown: return "## \(title)\n\(body)"
        }
    }

    static func numbered(_ steps: [String], goal: String = "") -> [String] {
        // Two steps is where an ordered list starts carrying information a
        // sentence cannot, so that is where numbering starts.
        guard steps.count > 1 else {
            // Dropped only when it really is the goal restated. Dropping every
            // single step is destructive once something else removes one:
            // hoisting a workflow directive out of a two-step list leaves one real
            // step behind, which would then vanish from the prompt entirely.
            guard let step = steps.first, !restates(step, goal) else { return [] }
            return [step]
        }
        return steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
    }

    /// Whether a step says what the goal already said.
    ///
    /// Containment either way rather than similarity scoring: the case this
    /// exists for is the model emitting the goal a second time as its only step,
    /// which is an exact or near-exact repeat, and anything cleverer would start
    /// deleting steps that merely share a verb.
    static func restates(_ step: String, _ goal: String) -> Bool {
        let a = step.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    static func section(
        _ title: String, _ items: [String], layout: PromptLayout, inlineSingle: Bool
    ) -> String {
        switch layout {
        case .claudeXML:
            // A one-item section stays on one line: `<task>…</task>` reads as a
            // value, and the three-line form suggests a list that isn't there.
            if inlineSingle, items.count == 1 { return "<\(title)>\(items[0])</\(title)>" }
            let body = items.map { bullet($0) }.joined(separator: "\n")
            return "<\(title)>\n\(body)\n</\(title)>"
        case .codexMarkdown:
            if items.count == 1 { return "## \(title)\n\(items[0])" }
            return "## \(title)\n" + items.map { bullet($0) }.joined(separator: "\n")
        }
    }

    /// A line already carrying its own ordinal keeps it; everything else gets a
    /// dash. Prefixing `- ` to `1. Rewrite the renderer` would read as a bullet
    /// containing a number rather than as step one.
    static func bullet(_ item: String) -> String {
        item.range(of: "^\\d+\\. ", options: .regularExpression) != nil ? item : "- \(item)"
    }

    // MARK: - Slash command

    static func renderCommand(
        _ ir: PromptIR,
        prompt: String,
        options: PromptRenderOptions,
        language: PromptOutputLanguage,
        symbols: [String],
        unresolved: [String]
    ) -> PromptArtifact {
        let name = options.nameOverride.map(slug) ?? derivedName(from: ir)
        let content = """
        ---
        description: \(singleLine(descriptionText(for: ir, language: language)))
        ---

        \(prompt)
        """
        return PromptArtifact(
            kind: .command,
            content: content,
            relativePath: ".claude/commands/\(name).md",
            usedSymbols: symbols,
            unresolvedSymbols: unresolved
        )
    }

    // MARK: - Skill

    static func renderSkill(
        _ ir: PromptIR,
        prompt: String,
        options: PromptRenderOptions,
        language: PromptOutputLanguage,
        symbols: [String],
        unresolved: [String]
    ) -> PromptArtifact {
        let name = options.nameOverride.map(slug) ?? derivedName(from: ir)
        let description = skillDescription(for: ir, language: language)
        let directory = ".claude/skills/\(name)"

        var body = prompt
        var companions: [PromptArtifactCompanion] = []

        // Past the practical ceiling, switch to progressive disclosure: the
        // SKILL.md keeps a routing table and the detail moves into one
        // reference file. References stay exactly one level deep, because
        // Claude partially reads files reached through a chain of references.
        if body.components(separatedBy: "\n").count > maxSkillBodyLines {
            let titles = SectionTitles.for(language, layout: .codexMarkdown)
            companions.append(PromptArtifactCompanion(
                relativePath: "\(directory)/references/details.md",
                content: "# \(titles.details)\n\n\(body)"
            ))
            body = """
            \(ir.goal)

            ## \(titles.loadOnlyWhatYouNeed)

            | \(titles.need) | \(titles.read) |
            |---|---|
            | \(titles.fullInstructions) | `references/details.md` |
            """
        }

        let content = """
        ---
        name: \(name)
        description: \(singleLine(description))
        ---

        \(body)
        """
        return PromptArtifact(
            kind: .skill,
            content: content,
            relativePath: "\(directory)/SKILL.md",
            usedSymbols: symbols,
            unresolvedSymbols: unresolved,
            companions: companions
        )
    }

    // MARK: - Rulebook

    /// The `.claude/rules/` file. Rules without `paths` load every session;
    /// rules with `paths` load only while Claude touches matching files, so a
    /// scoped rule costs nothing on unrelated work.
    public static func renderRulebook(
        _ rulebook: PromptRulebook,
        language: PromptOutputLanguage,
        backend: RuleBackend = .claude
    ) -> PromptArtifact {
        let scoped = rulebook.rules.filter { !$0.paths.isEmpty }
        let global = rulebook.rules.filter { $0.paths.isEmpty }

        var lines = [
            "# Prompt rule symbols",
            "",
            "Shorthand used in prompts written by Flow Translate. When a prompt lists a",
            "symbol under `Rules`, apply the matching instruction below.",
            "",
        ]
        // `fullStatement`, not `expansion`: for the eleven counter-intuitive rules
        // that appends the reason they exist.
        //
        // This is where a reason belongs. It is fixed content — the same sentence
        // for every prompt that ever cites the symbol — so putting it in the file
        // the project loads once per session costs it once, where printing it
        // inline charged ~25 tokens on every prompt that used the rule. The
        // prompt then carries the bare symbol and the reader resolves both the
        // instruction and the reason from here.
        for rule in global {
            lines.append("- **\(rule.symbol)** — \(rule.fullStatement(for: backend, language: language))")
        }
        if !scoped.isEmpty {
            lines.append("")
            lines.append("<!-- Path-scoped symbols live in sibling files so they load only when relevant. -->")
        }

        var companions: [PromptArtifactCompanion] = []
        for rule in scoped {
            let frontmatter = (["---", "paths:"] + rule.paths.map { "  - \"\($0)\"" } + ["---", ""])
                .joined(separator: "\n")
            companions.append(PromptArtifactCompanion(
                relativePath: ".claude/rules/flow-translate-\(slug(rule.symbol)).md",
                content: frontmatter + "\n- **\(rule.symbol)** — \(rule.fullStatement(for: backend, language: language))\n"
            ))
        }

        return PromptArtifact(
            kind: .rules,
            content: lines.joined(separator: "\n") + "\n",
            relativePath: ".claude/rules/flow-translate-symbols.md",
            usedSymbols: rulebook.rules.map(\.symbol),
            companions: companions
        )
    }

    /// Read back the symbols a rules file defines.
    ///
    /// The inverse of `renderRulebook`, and kept beside it deliberately: this
    /// pair is what decides whether bare symbols are safe to emit. If reading
    /// ever stopped matching writing, `syncedSymbols` would silently return
    /// nothing and the cheapest symbol mode would quietly never engage — a
    /// failure with no error to notice.
    public static func parseSymbols(from markdown: String) -> Set<String> {
        var symbols = Set<String>()
        var remainder = Substring(markdown)
        while let open = remainder.range(of: "**"),
              let close = remainder[open.upperBound...].range(of: "**") {
            let candidate = String(remainder[open.upperBound..<close.lowerBound])
            if PromptRulebook.isValidSymbol(candidate) { symbols.insert(candidate) }
            remainder = remainder[close.upperBound...]
        }
        return symbols
    }

    // MARK: - Naming and descriptions

    /// Common verbs in their gerund form. Anthropic's guidance prefers gerund
    /// skill names (`processing-pdfs`), and a lookup beats trying to conjugate
    /// English generically.
    static let gerunds: [String: String] = [
        "add": "adding", "build": "building", "create": "creating", "debug": "debugging",
        "document": "documenting", "extract": "extracting", "fix": "fixing",
        "implement": "implementing", "improve": "improving", "migrate": "migrating",
        "optimize": "optimizing", "port": "porting", "refactor": "refactoring",
        "remove": "removing", "rename": "renaming", "replace": "replacing",
        "review": "reviewing", "run": "running", "test": "testing", "update": "updating",
        "write": "writing",
    ]

    /// Reserved by Anthropic; a skill name containing either is rejected.
    static let reservedNameWords = ["claude", "anthropic"]
    static let maxNameLength = 64

    /// A valid `name` for SKILL.md frontmatter, derived from the goal.
    ///
    /// A Chinese-only goal leaves nothing usable after slugging — technical
    /// terms are usually still Latin ("refactor 這個 function"), but when even
    /// those are absent the name falls back to a generic one rather than
    /// emitting an invalid empty field.
    public static func derivedName(from ir: PromptIR) -> String {
        var words = ir.goal
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.allSatisfy(\.isASCII) && !$0.isEmpty }

        if let first = words.first, let gerund = gerunds[first] {
            words[0] = gerund
        }
        words = Array(words.prefix(5)).filter { word in
            !reservedNameWords.contains(where: { word.contains($0) })
        }

        let candidate = slug(words.joined(separator: "-"))
        return candidate.isEmpty ? "composed-prompt" : String(candidate.prefix(maxNameLength))
    }

    /// Lowercase, hyphen-separated, letters/digits only — the character set the
    /// frontmatter `name` field allows.
    public static func slug(_ text: String) -> String {
        var result = ""
        var lastWasHyphen = true
        for character in text.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    static let maxDescriptionLength = 1024

    /// Skill descriptions must be third person and state both *what* it does and
    /// *when* to use it — that pair is all Claude has when choosing among many
    /// skills.
    public static func skillDescription(for ir: PromptIR, language: PromptOutputLanguage) -> String {
        let what = descriptionText(for: ir, language: language)
        let when: String
        switch language {
        case .traditionalChinese:
            when = "當使用者要求執行這項任務時使用。"
        case .english:
            when = "Use when the user asks for this task."
        }
        return String("\(what) \(when)".prefix(maxDescriptionLength))
    }

    static func descriptionText(for ir: PromptIR, language: PromptOutputLanguage) -> String {
        let goal = ir.goal.isEmpty ? "Runs a composed task." : ir.goal
        // Third person: an imperative goal ("Add a retry") already reads that
        // way, so only first-person openers need rewriting.
        return singleLine(goal)
    }

    /// Frontmatter values are single-line, and must not carry XML tags.
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Section headings, localized and layout-aware. Kept in one place so the plain
/// prompt, the skill and the command never drift apart.
struct SectionTitles {
    let task: String
    /// Replaces `task` when the request is a question.
    let question: String
    /// The "answer first" block a question needs, and its two bodies: one for a
    /// question with no work attached, one for a request that asks *and*
    /// instructs.
    let answerFirst: String
    let answerOnlyBody: String
    let answerThenActBody: String
    let context: String
    let deliverables: String
    let constraints: String
    let exclusions: String
    let acceptance: String
    let failureCases: String
    let references: String
    let tools: String
    let rules: String
    let outOfScopeNote: String
    let details: String
    let loadOnlyWhatYouNeed: String
    let need: String
    let read: String
    let fullInstructions: String

    /// Anthropic's own "sample prompt for conservative action", verbatim.
    ///
    /// From the prompting best-practices page, offered for exactly this
    /// situation: "if you want the model to be more hesitant by default, less
    /// prone to jumping straight into implementations, and only take action if
    /// requested". A question with no work attached is that situation by
    /// definition, so the wording is taken rather than invented — it is the
    /// phrasing the people who trained the model published for the behaviour.
    static func answerOnlyBody(_ language: PromptOutputLanguage) -> String {
        switch language {
        case .traditionalChinese:
            return "先回答問題。除非我明確要求修改，否則不要直接動手實作或改檔案；"
                + "需求不明確時，預設是提供資訊、研究與建議，而不是採取行動。"
        case .english:
            return "Answer the question first. Do not jump into implementation or change files "
                + "unless clearly instructed to make changes. When the intent is ambiguous, "
                + "default to providing information, doing research, and providing "
                + "recommendations rather than taking action."
        }
    }

    /// The same block for a request that asks *and* instructs.
    ///
    /// "Do not act" would contradict the `<task>` tag directly above it, so this
    /// one orders the two rather than forbidding one. That contradiction is
    /// precisely what a single question-or-task classification could not avoid,
    /// and why the two are separate fields.
    static func answerThenActBody(_ language: PromptOutputLanguage) -> String {
        switch language {
        case .traditionalChinese:
            return "先回答上面的問題，再開始動手。如果答案會改變該怎麼做，先說出來，不要逕自照原計畫進行。"
        case .english:
            return "Answer the question before starting the work. If the answer changes what "
                + "should be done, say so rather than proceeding with the task as written."
        }
    }

    static func `for`(_ language: PromptOutputLanguage, layout: PromptLayout = .claudeXML) -> SectionTitles {
        // Tag and heading names stay English even for a Chinese prompt: they are
        // structural keywords the model keys off, they cost a third of what
        // their Chinese equivalents would, and every published convention on
        // both sides writes them this way. Only the prose inside is translated.
        if layout == .claudeXML {
            // snake_case tag names, per Anthropic's "consistent, descriptive
            // tag names" guidance.
            return SectionTitles(
                task: "task",
                question: "question",
                answerFirst: "answer_first",
                answerOnlyBody: Self.answerOnlyBody(language),
                answerThenActBody: Self.answerThenActBody(language),
                context: "context", deliverables: "output",
                constraints: "constraints", exclusions: "out_of_scope",
                acceptance: "done_when", failureCases: "risks", references: "files",
                tools: "tools", rules: "rules",
                outOfScopeNote: language == .traditionalChinese ? "不在範圍內" : "out of scope",
                details: "Full instructions", loadOnlyWhatYouNeed: "Load only what you need",
                need: "Need", read: "Read", fullInstructions: "Full instructions"
            )
        }
        // Codex: OpenAI's four building blocks — goal, context, format,
        // constraints — keeping our extra sections under names that read the
        // same way.
        switch language {
        case .traditionalChinese:
            return SectionTitles(
                task: "目標",
                question: "問題",
                answerFirst: "先回答，不要動手",
                answerOnlyBody: Self.answerOnlyBody(.traditionalChinese),
                answerThenActBody: Self.answerThenActBody(.traditionalChinese),
                context: "背景", deliverables: "產出", constraints: "約束",
                exclusions: "不要做", acceptance: "完成條件", failureCases: "已知風險",
                references: "相關檔案", tools: "建議工具", rules: "規則",
                outOfScopeNote: "不在範圍內", details: "完整指示",
                loadOnlyWhatYouNeed: "需要時才讀", need: "需求", read: "讀取",
                fullInstructions: "完整指示"
            )
        case .english:
            return SectionTitles(
                task: "Goal",
                question: "Question",
                answerFirst: "Answer first",
                answerOnlyBody: Self.answerOnlyBody(.english),
                answerThenActBody: Self.answerThenActBody(.english),
                context: "Context", deliverables: "Output",
                constraints: "Constraints", exclusions: "Out of scope", acceptance: "Done when",
                failureCases: "Known risks", references: "Files", tools: "Suggested tools",
                rules: "Rules", outOfScopeNote: "out of scope", details: "Full instructions",
                loadOnlyWhatYouNeed: "Load only what you need", need: "Need", read: "Read",
                fullInstructions: "Full instructions"
            )
        }
    }
}
