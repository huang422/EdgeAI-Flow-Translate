import Foundation

/// Which coding agent a rule is being rendered for.
///
/// The same rule is worded differently per agent because the agents differ.
/// Claude Code follows instructions closely and reads `.claude/rules/`; Codex
/// and the other AGENTS.md tools read one shared Markdown file and respond
/// better to short declaratives.
public enum RuleBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    /// Anything else, and the fallback whenever a rule omits a backend.
    case generic

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex / AGENTS.md"
        case .generic: return "通用 Generic"
        }
    }
}

/// Which area of practice a rule belongs to. Drives the stdlib file it ships in
/// and the grouping in the editor.
public enum RuleCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case coding
    case testing
    case architecture
    case security
    case git
    case performance
    /// How the agent should *work*, as opposed to what it should build.
    ///
    /// Added because the other six categories describe the artifact and none of
    /// them has a place for "explain before you implement" or "search the web
    /// rather than trusting your training data". The empirical study of 253
    /// CLAUDE.md files (arXiv 2509.14744) found Development Process in 37.2% of
    /// real manifests — the single largest category with no home here.
    case workflow
    /// Reviewing code someone (or something) else wrote.
    ///
    /// Kept apart from `testing` because the failure mode is the opposite one.
    /// A weak test suite misses defects; a weak review *invents* them, and the
    /// cost of that is now measurable outside any one project — curl closed its
    /// bug bounty after AI-generated reports drove the confirmed rate below 5%,
    /// and HackerOne paused the Internet Bug Bounty in March 2026 citing the
    /// same volume. Precision is the whole problem.
    case review

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .coding: return "程式撰寫 Coding"
        case .testing: return "測試 Testing"
        case .architecture: return "架構 Architecture"
        case .security: return "安全 Security"
        case .git: return "版控 Git"
        case .performance: return "效能 Performance"
        case .workflow: return "工作流程 Workflow"
        case .review: return "程式碼審查 Code review"
        }
    }
}

/// One rule, specified the way an RFC specifies a standard: a stable id, a
/// definition, worked examples, and an authority it derives from.
///
/// Two separate alias fields, deliberately:
/// - `aliases` are alternate **identifiers** (`API_STABLE` for `KEEP_API`), for
///   humans and other rulebooks to reference the same rule by another name.
/// - `match` are natural-language **phrasings**, in either language, that the
///   deterministic matcher uses to recognise the rule in a spoken request.
///
/// Conflating them would mean either the matcher tries to match identifiers or
/// a user writing `API_STABLE` gets no rule.
public struct PromptRule: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity, independent of `symbol`, so renaming in the editor does
    /// not change which row is selected.
    public var id: UUID
    /// The identifier a prompt writes. `UPPER_SNAKE`, English, always.
    public var symbol: String
    public var category: RuleCategory
    /// Alternate identifiers for the same rule.
    public var aliases: [String]
    /// Natural-language phrasings the matcher recognises, in any language.
    public var match: [String]
    /// One sentence saying what the rule means.
    public var description: String
    /// Concrete instances. Shown in the editor; not sent in prompts.
    public var examples: [String]
    /// Per-agent wording. `generic` is the fallback for any missing backend.
    public var backends: [RuleBackend: String]
    /// Traditional Chinese wording, used when the prompt is rendered in zh-Hant.
    public var zhHant: String?
    /// Where the rule comes from. Required — a rule nobody can trace is a rule
    /// nobody should be asked to follow.
    public var source: String
    /// Optional glob scoping for `.claude/rules/` frontmatter. When set, the
    /// rule loads only while the agent touches matching files, which drops its
    /// cost from once-per-session to only-when-relevant.
    public var paths: [String]
    /// Whether obeying this rule means *not* doing the obvious thing.
    ///
    /// This is the one field that changes how a rule is rendered rather than
    /// what it says. Compact Constraint Encoding for LLM Code Generation
    /// (arXiv 2604.07192; 6 rounds, 11 models, 830+ invocations) found that
    /// symbol-versus-sentence encoding makes no measurable difference to whether
    /// a constraint is obeyed (Cliff's δ < 0.01) — but that **counter-intuitive
    /// constraints are satisfied only 10–100% of the time while conventional
    /// ones reach 99%+, regardless of encoding**. Compliance is a property of
    /// the constraint, not of its formatting.
    ///
    /// So a rule marked here is never emitted as a bare symbol. It gets its full
    /// wording plus its `rationale`, because Anthropic's prompting guide finds
    /// that stating *why* an instruction exists outperforms stating it alone.
    /// The tokens are spent where they are the only thing that helps.
    public var counterIntuitive: Bool
    /// Why the rule exists. Emitted alongside counter-intuitive rules.
    public var rationale: String?
    /// The same reason in Traditional Chinese.
    ///
    /// Required wherever `rationale` is set, and a test enforces it. The eleven
    /// counter-intuitive rules compress to `SYMBOL — reason`, so without this the
    /// reason is the one part of a Chinese prompt with no Chinese form:
    /// `WEB_SEARCH — training data has a cutoff…`.
    public var rationaleZhHant: String?
    /// The same rule stated as what to do rather than what to avoid.
    ///
    /// Anthropic's guidance is that positive examples of the wanted behaviour
    /// beat prohibitions. Most of this rulebook is necessarily `NO_*`, so where
    /// a rule can be turned around honestly, the positive form is preferred when
    /// rendering for Claude.
    ///
    /// It **replaces** the backend wording rather than leading it, so it has to
    /// carry everything that wording carried. A positive form that reads better
    /// and says less is a worse rule, not a better-framed one — the first draft
    /// of `LIMIT_DELEGATION` dropped "do not use subagents to verify your own
    /// work" on the way to being shorter, and only a conformance test noticed.
    public var positiveForm: String?
    /// Whether this rule differs from the bundled one.
    ///
    /// Stamped on save by comparing against the stdlib rather than tracked by the
    /// editor, so it cannot go stale: any field the user changes, and any rule
    /// they add, sets it. It exists for one job — deciding what an upgrade may
    /// replace. A rule the user never touched is the app's to improve; one they
    /// edited is theirs, and an upgrade must leave it alone.
    public var isUserEdited: Bool = false

    public init(
        id: UUID = UUID(),
        symbol: String,
        category: RuleCategory = .coding,
        aliases: [String] = [],
        match: [String] = [],
        description: String,
        examples: [String] = [],
        backends: [RuleBackend: String] = [:],
        zhHant: String? = nil,
        source: String,
        paths: [String] = [],
        counterIntuitive: Bool = false,
        rationale: String? = nil,
        rationaleZhHant: String? = nil,
        positiveForm: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.category = category
        self.aliases = aliases
        self.match = match
        self.description = description
        self.examples = examples
        self.backends = backends
        self.zhHant = zhHant
        self.source = source
        self.paths = paths
        self.counterIntuitive = counterIntuitive
        self.rationale = rationale
        self.rationaleZhHant = rationaleZhHant
        self.positiveForm = positiveForm
    }

    // Declared explicitly: providing both `init(from:)` and `encode(to:)`
    // leaves nothing for the compiler to synthesize the keys from.
    enum CodingKeys: String, CodingKey {
        case id, symbol, category, aliases, match, description
        case examples, backends, zhHant, source, paths
        case counterIntuitive, rationale, rationaleZhHant, positiveForm, isUserEdited
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? ""
        let rawCategory = (try? c.decode(String.self, forKey: .category)) ?? ""
        category = RuleCategory(rawValue: rawCategory) ?? .coding
        aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        match = (try? c.decode([String].self, forKey: .match)) ?? []
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        examples = (try? c.decode([String].self, forKey: .examples)) ?? []
        zhHant = try? c.decode(String.self, forKey: .zhHant)
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        paths = (try? c.decode([String].self, forKey: .paths)) ?? []
        counterIntuitive = (try? c.decode(Bool.self, forKey: .counterIntuitive)) ?? false
        rationale = try? c.decode(String.self, forKey: .rationale)
        rationaleZhHant = try? c.decode(String.self, forKey: .rationaleZhHant)
        positiveForm = try? c.decode(String.self, forKey: .positiveForm)
        isUserEdited = (try? c.decode(Bool.self, forKey: .isUserEdited)) ?? false
        // Unknown backend keys are dropped rather than failing the whole rule.
        let raw = (try? c.decode([String: String].self, forKey: .backends)) ?? [:]
        backends = raw.reduce(into: [:]) { result, pair in
            if let backend = RuleBackend(rawValue: pair.key) { result[backend] = pair.value }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(category.rawValue, forKey: .category)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(match, forKey: .match)
        try c.encode(description, forKey: .description)
        try c.encode(examples, forKey: .examples)
        try c.encode(backends.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value },
                     forKey: .backends)
        try c.encodeIfPresent(zhHant, forKey: .zhHant)
        try c.encode(source, forKey: .source)
        try c.encode(paths, forKey: .paths)
        try c.encode(counterIntuitive, forKey: .counterIntuitive)
        try c.encodeIfPresent(rationale, forKey: .rationale)
        try c.encodeIfPresent(rationaleZhHant, forKey: .rationaleZhHant)
        try c.encodeIfPresent(positiveForm, forKey: .positiveForm)
        try c.encode(isUserEdited, forKey: .isUserEdited)
    }

    /// The wording to emit for a given agent and language.
    ///
    /// Falls back backend → generic → description, so a rule is never rendered
    /// as an empty string just because it omits one agent.
    ///
    /// `positiveForm` wins for Claude when one exists **and conforms**:
    /// Anthropic's prompting guide reports that showing the wanted behaviour
    /// outperforms forbidding the unwanted one. It is not applied to Codex, whose
    /// guidance favours short declaratives and where the prohibition is the
    /// shorter statement.
    ///
    /// A form that fails `positiveFormIssues()` is ignored rather than emitted.
    /// It replaces the prohibition, so a form that quietly drops it does not
    /// reframe the rule — it deletes it. That was not hypothetical: `NO_DEPS`
    /// rendered as "Solve it with what the project already depends on", so a user
    /// who dictated "don't add any new dependencies" got a prompt containing no
    /// prohibition at all, and `KEEP_API` rendered as "Preserve every existing
    /// public signature and behaviour", dropping the identifier `API` that the
    /// request had named. A live eval scored both as inverted meaning; reading
    /// the output would not have.
    public func expansion(for backend: RuleBackend, language: PromptOutputLanguage = .english) -> String {
        if language == .traditionalChinese, let zh = zhHant, !zh.isEmpty { return zh }
        if backend == .claude, let positive = positiveForm, !positive.isEmpty,
           positiveFormIssues().isEmpty {
            return positive
        }
        if let specific = backends[backend], !specific.isEmpty { return specific }
        if let generic = backends[.generic], !generic.isEmpty { return generic }
        return description
    }

    /// Why this rule's `positiveForm` cannot stand in for its prohibition, empty
    /// when it can.
    ///
    /// Two checks, both derived from the failure they were written for:
    ///
    /// - **Polarity.** A rule whose definition forbids something must still
    ///   forbid it after reframing. "Say what you want" is advice about phrasing,
    ///   not licence to drop the constraint — and a prompt that no longer forbids
    ///   anything reads as though the user never asked.
    /// - **Named things.** Identifiers, acronyms and paths in the definition must
    ///   survive. `KEEP_API` without the letters `API` is a different, vaguer
    ///   rule, and the terms are exactly what a reader greps for.
    ///
    /// Reported rather than thrown, so a user's own lossy positive form shows up
    /// in the rulebook editor's footer instead of silently degrading their
    /// prompts.
    public func positiveFormIssues() -> [String] {
        guard let positive = positiveForm?.trimmingCharacters(in: .whitespacesAndNewlines),
              !positive.isEmpty
        else { return [] }

        var issues: [String] = []
        if SymbolCompressor.isNegated(description), !SymbolCompressor.isNegated(positive) {
            issues.append(
                "`\(symbol)` 的正面說法沒有保留禁止語氣，會讓 prompt 讀起來像沒有這條限制。"
                + " The positive form drops the prohibition."
            )
        }
        let named = LexicalCompressor.codeSpans(in: description)
            .map { String(description[$0]) }
            .filter { $0.count > 1 }
        let lowered = positive.lowercased()
        for term in Set(named) where !lowered.contains(term.lowercased()) {
            issues.append("`\(symbol)` 的正面說法漏掉了 `\(term)`. The positive form drops `\(term)`.")
        }
        return issues
    }

    /// The wording plus its reason, for rules that need the reason to be obeyed.
    ///
    /// Only counter-intuitive rules pay for this. Spending the tokens on every
    /// rule would be waste: conventional constraints already reach 99%+
    /// compliance from the bare symbol alone (arXiv 2604.07192).
    public func fullStatement(
        for backend: RuleBackend, language: PromptOutputLanguage = .english
    ) -> String {
        let statement = expansion(for: backend, language: language)
        guard let reason = reason(in: language), !reason.isEmpty else { return statement }
        return "\(statement) — \(reason)"
    }

    /// Why the rule exists, in `language`.
    ///
    /// Falls back to the English text rather than printing nothing: a missing
    /// translation should cost a language mismatch, not the reason itself — and
    /// `validationErrors()` reports the gap so it gets written.
    public func reason(in language: PromptOutputLanguage) -> String? {
        language == .traditionalChinese ? (rationaleZhHant ?? rationale) : rationale
    }

    /// Everything the deterministic matcher may compare a candidate against:
    /// the phrasings, the alternate identifiers, and the definition itself.
    var matchTargets: [String] { match + aliases + [description] + backends.values }

    /// Problems that make this rule unusable, empty when it is fine.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if symbol.isEmpty {
            errors.append("A rule is missing its symbol.")
        } else if !PromptRulebook.isValidSymbol(symbol) {
            errors.append("`\(symbol)` is not a valid symbol — use UPPER_SNAKE_CASE.")
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("`\(symbol)` has no description.")
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("`\(symbol)` has no source. Every rule must be traceable.")
        }
        if rationale != nil, rationaleZhHant == nil {
            errors.append("`\(symbol)` 有英文理由但沒有中文理由。 `\(symbol)` has an English "
                + "rationale with no Traditional Chinese one, so a Chinese prompt would "
                + "carry an English reason.")
        }
        errors += positiveFormIssues()
        errors += deadPhrasings().map {
            "`\(symbol)` 的口語變體「\($0)」永遠比對不到。"
                + " Phrasing \"\($0)\" can never match — it needs two informative words."
        }
        return errors
    }

    /// Advertised phrasings the matcher can never resolve.
    ///
    /// `SymbolCompressor.overlap` requires two shared *informative* tokens before
    /// it will call two phrases the same rule — a floor that exists because one
    /// shared common word ("no", "the") is not evidence of anything. The
    /// consequence, which nothing checked, is that a phrasing whose own content
    /// reduces to a single informative token can never clear the floor no matter
    /// what the user says.
    ///
    /// Thirteen of the shipped phrasings were in that state: `deterministic`,
    /// `no eval`, `be concise`, `do it yourself`, `no stubs` and friends were
    /// listed in the rulebook editor as "say this and you get this symbol", and
    /// saying it did nothing at all.
    ///
    /// Reported rather than silently widened, because the alternative — letting a
    /// single token carry a match — is how `"run the eval suite"` would resolve
    /// to `NO_EVAL` in a project whose evals are the thing being discussed.
    public func deadPhrasings() -> [String] {
        match.filter { phrase in
            SymbolCompressor.informativeTokens(of: phrase).count < SymbolCompressor.minimumSharedTokens
        }
    }
}

/// A collection of rules — the "prompt stdlib" when it is the bundled one, a
/// project's own rulebook when the user has edited it.
public struct PromptRulebook: Codable, Sendable, Equatable {
    public var rules: [PromptRule]

    /// Which bundled stdlib this book was last reconciled with.
    ///
    /// Zero for anything saved before versioning existed, which is the signal to
    /// upgrade it. See `upgrading(_:to:)`.
    public var stdlibVersion: Int

    public init(rules: [PromptRule] = [], stdlibVersion: Int = PromptStdlib.version) {
        self.rules = rules
        self.stdlibVersion = stdlibVersion
    }

    enum CodingKeys: String, CodingKey { case rules, stdlibVersion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = (try? c.decode([PromptRule].self, forKey: .rules)) ?? []
        stdlibVersion = (try? c.decode(Int.self, forKey: .stdlibVersion)) ?? 0
    }

    /// Mark which rules the user has actually changed, by comparing to `stdlib`.
    ///
    /// Called on every save. Comparing rather than tracking means the flag is
    /// always right, including for rules edited before the flag existed and for
    /// an edit that happens to restore the bundled wording.
    public func stampingUserEdits(against stdlib: PromptRulebook) -> PromptRulebook {
        var result = self
        for index in result.rules.indices {
            var mine = result.rules[index]
            guard var theirs = stdlib.rule(for: mine.symbol) else {
                // A symbol the stdlib does not know is one the user added.
                result.rules[index].isUserEdited = true
                continue
            }
            // `id` is per-install and the flag is what is being computed, so
            // neither counts as a difference.
            theirs.id = mine.id
            theirs.isUserEdited = false
            mine.isUserEdited = false
            result.rules[index].isUserEdited = mine != theirs
        }
        result.stdlibVersion = PromptStdlib.version
        return result
    }

    /// Reconcile a saved rulebook with a newer bundled one.
    ///
    /// A rulebook is written to `UserDefaults` the first time anything saves one,
    /// so letting the saved book win outright makes it permanent and **every
    /// improvement to the bundled rules invisible** to that install — fixed
    /// phrasings still reported as problems, new `WEB_SEARCH` phrasings never
    /// matching.
    ///
    /// The bundled rules win for anything the user has not edited; their own
    /// edits and their own rules win over the bundle and survive every upgrade.
    public static func upgrading(_ stored: PromptRulebook, to stdlib: PromptRulebook) -> PromptRulebook {
        guard stored.stdlibVersion < stdlib.stdlibVersion else { return stored }

        // Which rules are the user's, by two different tests depending on what
        // the saved book can tell us.
        //
        // From version 1 on, `isUserEdited` was stamped at save time — against
        // the bundle as it stood *then*, which is the only moment the comparison
        // is meaningful — so it is simply read.
        //
        // Version 0 predates the flag, and there is no way to recover the
        // information: comparing those rules to the current bundle answers "did
        // this rule change?", not "did the user change it?", and after the bundle
        // moves on the answer is yes for every rule that most needs replacing.
        // Written that way, the upgrade preserved precisely the stale copies it
        // existed to retire. So for version 0 only a symbol the bundle has never
        // heard of counts as the user's — a rule they added — and everything else
        // comes from the app.
        let mine: [PromptRule] = stored.stdlibVersion == 0
            ? stored.rules.filter { stdlib.rule(for: $0.symbol) == nil }
            : stored.rules.filter(\.isUserEdited)
        let mineSymbols = Set(mine.map(\.symbol))
        // Bundled first, in the stdlib's own order, so the categories still read
        // in the order they were written; the user's own rules follow.
        let bundled = stdlib.rules.filter { !mineSymbols.contains($0.symbol) }
        let kept = mine.map { rule -> PromptRule in
            var rule = rule
            rule.isUserEdited = true   // now recorded, so the next upgrade knows
            return rule
        }
        return PromptRulebook(rules: bundled + kept, stdlibVersion: stdlib.stdlibVersion)
    }

    public func rule(for symbol: String) -> PromptRule? {
        // Alternate identifiers resolve to the same rule.
        rules.first { $0.symbol == symbol } ?? rules.first { $0.aliases.contains(symbol) }
    }

    public var symbols: Set<String> { Set(rules.map(\.symbol)) }

    public func rules(in category: RuleCategory) -> [PromptRule] {
        rules.filter { $0.category == category }
    }

    /// A rulebook narrowed to the given categories.
    ///
    /// Used when installing into a project: the generated file loads at every
    /// session start, so categories the project never uses are a permanent cost
    /// on every conversation there rather than a one-off.
    public func filtered(to categories: Set<RuleCategory>) -> PromptRulebook {
        PromptRulebook(rules: rules.filter { categories.contains($0.category) })
    }

    /// `UPPER_SNAKE`, starting with a letter.
    public static func isValidSymbol(_ symbol: String) -> Bool {
        guard let first = symbol.first, first.isLetter, first.isUppercase, first.isASCII else { return false }
        guard symbol.count <= 40 else { return false }
        return symbol.allSatisfy { ($0.isUppercase && $0.isASCII) || $0 == "_" || ($0.isNumber && $0.isASCII) }
    }

    /// Every problem across the book, including duplicate identifiers. Reported
    /// rather than thrown so one bad row never blocks the rest.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        for rule in rules {
            errors += rule.validationErrors()
            guard !rule.symbol.isEmpty else { continue }
            if !seen.insert(rule.symbol).inserted {
                errors.append("`\(rule.symbol)` is defined more than once.")
            }
            for alias in rule.aliases where !seen.insert(alias).inserted {
                errors.append("`\(alias)` collides with another symbol.")
            }
        }
        return errors
    }

    public mutating func merge(_ other: PromptRulebook) {
        let existing = symbols
        rules += other.rules.filter { !existing.contains($0.symbol) }
    }

    /// Rules that have something wrong with them, for the editor to flag.
    public var invalidRuleIDs: Set<UUID> {
        Set(rules.filter { !$0.validationErrors().isEmpty }.map(\.id))
    }

    /// Whether every problem in this book is one `repairingPhrasings` can fix.
    public var issuesAreRepairable: Bool {
        !validationErrors().isEmpty
            && rules.allSatisfy { rule in
                rule.validationErrors().count == rule.deadPhrasings().count
            }
    }

    /// Replace unmatchable phrasings with the reference book's corrected ones.
    ///
    /// A saved rulebook is a snapshot. When the bundled library fixes something —
    /// and it did: thirteen advertised phrasings reduced to a single informative
    /// word and could never clear the matcher's two-token floor — every user who
    /// had already opened the editor keeps the broken snapshot, because
    /// `RulebookStore` prefers what is on disk. The validator then correctly
    /// reports thirteen problems the user did not cause and has no obvious way to
    /// fix: "reset to bundled" is the only button, and it throws away their own
    /// rules along with the stale ones.
    ///
    /// So this repairs **only what is flagged**. For each dead phrasing it takes
    /// the reference book's phrasings for the same symbol; anything the user
    /// added themselves, and every rule the reference does not know about, is
    /// untouched. A dead phrasing with no reference to draw on is dropped, since
    /// a phrasing that can never match is worse than no phrasing at all — it is
    /// advertised in the editor as "say this and you get this symbol".
    public func repairingPhrasings(using reference: PromptRulebook) -> PromptRulebook {
        var result = self
        for index in result.rules.indices {
            let dead = Set(result.rules[index].deadPhrasings())
            guard !dead.isEmpty else { continue }
            var kept = result.rules[index].match.filter { !dead.contains($0) }
            if let source = reference.rule(for: result.rules[index].symbol) {
                for phrase in source.match
                where !kept.contains(phrase) && !dead.contains(phrase) {
                    kept.append(phrase)
                }
            }
            result.rules[index].match = kept
        }
        return result
    }
}
