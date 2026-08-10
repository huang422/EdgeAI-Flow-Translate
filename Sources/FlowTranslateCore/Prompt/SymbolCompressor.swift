import Foundation

/// Replaces spelled-out constraints with rulebook symbols — the largest single
/// token saving available, because it shortens *meaning* rather than wording.
///
/// A 12-word English constraint costs roughly 14 tokens every time it appears.
/// `NO_DEPS` costs about three. The full sentence is paid for once per session
/// in `.claude/rules/`, which Claude Code loads at startup, so from the second
/// prompt onward the difference is pure profit.
///
/// Matching happens twice, on purpose. The intent-extraction prompt already
/// carries the symbol catalogue and asks the model to emit symbols directly —
/// that costs nothing extra and handles most cases. This type is the
/// deterministic backstop for the prose that slips through, and unlike the
/// model it is fully unit-testable.
public enum SymbolCompressor {

    /// Fraction of the shorter token set that must be shared before two phrases
    /// are considered the same rule. Tuned to accept real paraphrases
    /// ("no new dependencies" vs. "do not add new third-party dependencies")
    /// while a negation guard blocks the dangerous near-misses.
    static let matchThreshold = 0.65

    /// The result of compressing one IR.
    public struct Result: Sendable, Equatable {
        public var ir: PromptIR
        /// Symbols that ended up in the output, in first-use order.
        public var usedSymbols: [String]
    }

    /// Rewrite constraints, exclusions and acceptance criteria into symbols
    /// wherever the rulebook covers them.
    public static func compress(
        _ ir: PromptIR,
        rulebook: PromptRulebook,
        backend: RuleBackend = .claude,
        language: PromptOutputLanguage = .english
    ) -> Result {
        guard !rulebook.rules.isEmpty else { return Result(ir: ir, usedSymbols: []) }

        var result = ir
        var used: [String] = []

        func rewrite(_ items: [String]) -> [String] {
            var output: [String] = []
            for item in items {
                guard let symbol = match(item, in: rulebook) else {
                    output.append(item)
                    continue
                }
                // Every rule compresses to a **bare** symbol, including the
                // eleven counter-intuitive ones.
                //
                // Exempting them costs four times the tokens for nothing
                // measurable: Compact Constraint Encoding (arXiv 2604.07192)
                // measured symbol against sentence at Cliff's δ < 0.01, so
                // encoding makes no difference to compliance either way.
                //
                // The reason does move compliance, per Anthropic's guidance — but
                // it is fixed content, identical in every prompt citing the
                // symbol, so it belongs in the rules file the project loads once
                // per session (`renderRulebook` writes it there). Three tokens
                // reach the prompt instead of twenty-eight, and the reader still
                // has the reason. The modes with no synced file carry it anyway:
                // `off` expands through `fullStatement`, and the legend spells it
                // out.

                // A constraint that names something the symbol cannot name keeps
                // its sentence. `KEEP_API` says "preserve the public API"; it has
                // no way to say *whose*. Compressing "不要動 OrderRepository 的公開
                // API" into it silently widens a scoped instruction into a global
                // one and deletes the identifier on the way — and the prompt still
                // reads perfectly, which is why a live eval caught it and no
                // amount of reading the output would have.
                //
                // The English form of the same sentence escaped only by accident:
                // the extra identifier dragged token overlap below the matching
                // threshold. Relying on that is relying on a near miss.
                if let rule = rulebook.rule(for: symbol),
                   carriesScopeBeyond(rule, item: item, backend: backend, language: language) {
                    output.append(item)
                    continue
                }
                if !used.contains(symbol) { used.append(symbol) }
                // A symbol already present earlier in this section adds nothing
                // the second time.
                if !output.contains(symbol) { output.append(symbol) }
            }
            return output
        }

        // Move directives about *how to work* into constraints before rewriting.
        //
        // Only three sections are ever compressed, because only they hold
        // constraints — but the compiler does not reliably put a constraint in
        // one. "先上網搜尋目前最佳實作方式" is phrased as a step (先…再…), so a 4B
        // model files it under `steps`, and from there it can never become a
        // symbol however many phrasings the rulebook lists. That is why
        // "上網搜尋" kept coming back as a sentence: the matcher was never asked.
        //
        // Hoisting is also the more accurate reading. Searching the web first is
        // not a unit of the work; it is a condition on doing it, which is what a
        // constraint is. Only whole-item matches against `workflow` and `review`
        // rules move — a step that merely mentions one keeps its place.
        hoistWorkflowDirectives(&result, rulebook: rulebook, backend: backend, language: language)

        result.constraints = rewrite(result.constraints)
        result.scopeExclusions = rewrite(result.scopeExclusions)
        result.acceptance = rewrite(result.acceptance)
        dropRepeatsAcrossSections(&result)
        return Result(ir: result, usedSymbols: used)
    }

    /// Move whole-item matches on "how to work" rules out of `steps` and
    /// `context` and into `constraints`.
    ///
    /// Conservative on both axes. Only `.workflow` and `.review` categories move
    /// — a `.testing` or `.security` rule can legitimately *be* a step ("run the
    /// migration", "rotate the key") — and only when the entire item resolves to
    /// the rule, so a step that names a file or a function alongside it stays
    /// where the compiler put it.
    static func hoistWorkflowDirectives(
        _ ir: inout PromptIR,
        rulebook: PromptRulebook,
        backend: RuleBackend,
        language: PromptOutputLanguage
    ) {
        func hoist(_ items: inout [String]) {
            var kept: [String] = []
            for item in items {
                guard let symbol = match(item, in: rulebook),
                      let rule = rulebook.rule(for: symbol),
                      rule.category == .workflow || rule.category == .review,
                      // The same guard the rewrite uses, plus a stricter one.
                      // Moving an item is a bigger claim than rewriting it in
                      // place — it says the item was filed in the wrong section —
                      // so anything naming a specific thing stays put.
                      !carriesScopeBeyond(rule, item: item, backend: backend, language: language),
                      !namesSomethingSpecific(item, beyond: rule)
                else {
                    kept.append(item)
                    continue
                }
                if !ir.constraints.contains(item) { ir.constraints.append(item) }
            }
            items = kept
        }
        hoist(&ir.steps)
        hoist(&ir.context)
    }

    /// Whether `item` names an identifier the rule's own vocabulary does not.
    ///
    /// `carriesScopeBeyond` asks the same question of `codeSpans`, which wants a
    /// dot, a slash or an underscore to call something code — so a bare
    /// `URLSession` or `uploadChunk` slips past it. "上網搜尋 URLSession 的重試最佳
    /// 做法" would then be hoisted to a bare `WEB_SEARCH` and the type name would
    /// be gone from the prompt.
    ///
    /// Identifier-shaped rather than unknown-word-shaped, deliberately: "search
    /// online for the best approach" contains four words the rule never lists and
    /// names nothing, while `URLSession`, `S3` and `uploadChunk` all carry an
    /// internal capital or a digit. Ordinary prose does not.
    static func namesSomethingSpecific(_ item: String, beyond rule: PromptRule) -> Bool {
        let known = ([rule.symbol, rule.description] + rule.match + rule.aliases
            + rule.examples + Array(rule.backends.values))
            .joined(separator: " ")
            .lowercased()

        for token in item.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            guard token.count >= 2, token.allSatisfy({ $0.isASCII }) else { continue }
            let hasInnerCapital = token.dropFirst().contains(where: \.isUppercase)
            let hasDigit = token.contains(where: \.isNumber)
            guard hasInnerCapital || hasDigit else { continue }
            if !known.contains(token.lowercased()) { return true }
        }
        return false
    }

    /// A rule stated once is a rule; stated twice it is noise.
    ///
    /// The model routinely emits the same requirement in two places — "測試要過"
    /// as a constraint and "既有測試全數通過" as an acceptance criterion — and both
    /// legitimately compress to `TEST_PASS`. `PromptOptimizer` deduplicates within
    /// a section and cannot see across them, so the prompt carried the symbol
    /// twice, and once it was expanded (which is what happens whenever the project
    /// has no synced rulebook) that became the same twelve-token sentence printed
    /// under two different headings.
    ///
    /// The first occurrence wins, in render order: constraints, then out of scope,
    /// then done-when. Keeping the earliest means no section can be emptied by a
    /// rule that was already stated further down, and the reader meets the rule at
    /// the first point it applies.
    static func dropRepeatsAcrossSections(_ ir: inout PromptIR) {
        var seen = Set<String>()
        func keepFirst(_ items: [String]) -> [String] {
            items.filter { item in
                // Only symbols, bare or annotated. Two prose bullets that happen
                // to overlap are `PromptOptimizer`'s near-duplicate problem, and
                // it has the token-overlap machinery to judge them.
                guard let symbol = leadingSymbol(of: item) else { return true }
                return seen.insert(symbol).inserted
            }
        }
        ir.constraints = keepFirst(ir.constraints)
        ir.scopeExclusions = keepFirst(ir.scopeExclusions)
        ir.acceptance = keepFirst(ir.acceptance)
    }

    /// The symbol at the head of an annotated bullet, or the bullet itself.
    ///
    /// `expand` and the renderer both have to recognise `SYMBOL — reason` as the
    /// symbol it carries; matching only bare identifiers would leave a
    /// counter-intuitive rule unexpandable, which is the state the old code
    /// avoided by never producing one.
    public static func leadingSymbol(of item: String) -> String? {
        let head = item.components(separatedBy: " — ").first ?? item
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        return PromptRulebook.isValidSymbol(trimmed) ? trimmed : nil
    }

    /// Whether `item` names an identifier, path or flag that the rule's own
    /// wording does not — meaning the sentence is scoped and the symbol is not.
    ///
    /// Compared against the rule's whole vocabulary, not just one backend's
    /// phrasing, so a rule that mentions `API` in its description is not treated
    /// as losing information when a constraint mentions `API` too.
    static func carriesScopeBeyond(
        _ rule: PromptRule, item: String, backend: RuleBackend, language: PromptOutputLanguage
    ) -> Bool {
        let identifiers = LexicalCompressor.codeSpans(in: item)
            .map { String(item[$0]) }
            .filter { $0.count > 1 }
        guard !identifiers.isEmpty else { return false }

        let known = ([
            rule.symbol, rule.description,
            rule.expansion(for: backend, language: language),
        ] + rule.match + rule.aliases + rule.examples + Array(rule.backends.values))
            .joined(separator: " ")
            .lowercased()

        return identifiers.contains { !known.contains($0.lowercased()) }
    }

    /// Expand every symbol back into full text — what `.off` does with a
    /// symbol-laden IR, and the automatic fallback when a symbol cannot be
    /// guaranteed defined.
    public static func expand(
        _ ir: PromptIR,
        rulebook: PromptRulebook,
        language: PromptOutputLanguage,
        backend: RuleBackend = .claude
    ) -> PromptIR {
        var result = ir
        func expandAll(_ items: [String]) -> [String] {
            PromptIR.normalize(items.map { item in
                // `SYMBOL — reason` as well as a bare `SYMBOL`: a
                // counter-intuitive rule arrives annotated, and expanding to the
                // full statement re-attaches the same reason at the end.
                guard let symbol = leadingSymbol(of: item) ?? (rulebook.rule(for: item) != nil ? item : nil),
                      let rule = rulebook.rule(for: symbol)
                else { return item }
                return rule.fullStatement(for: backend, language: language)
            })
        }
        result.constraints = expandAll(ir.constraints)
        result.scopeExclusions = expandAll(ir.scopeExclusions)
        result.acceptance = expandAll(ir.acceptance)
        return result
    }

    /// The legend appended in `.symbolsWithLegend` mode: the minimum needed for
    /// a reader with no rulebook to resolve every symbol used.
    public static func legend(
        for symbols: [String],
        rulebook: PromptRulebook,
        language: PromptOutputLanguage,
        backend: RuleBackend = .claude
    ) -> [String] {
        symbols.compactMap { symbol -> String? in
            guard let rule = rulebook.rule(for: symbol) else { return nil }
            // Definition **and** reason: this is the mode for a reader with no
            // rules file, so the legend is the only place either can come from.
            return "\(symbol) = \(rule.fullStatement(for: backend, language: language))"
        }
    }

    /// Downgrade the requested mode when it would emit a symbol the target
    /// project cannot resolve.
    ///
    /// `symbolsAssumeRulebook` is only honest once the rulebook is actually on
    /// disk in the project. Emitting a bare `NO_DEPS` that nothing defines
    /// leaves Claude guessing, which is strictly worse than spending the tokens
    /// — so an unmet requirement silently becomes `symbolsWithLegend` rather
    /// than a broken prompt.
    public static func effectiveMode(
        requested: PromptSymbolMode,
        usedSymbols: [String],
        syncedSymbols: Set<String>
    ) -> PromptSymbolMode {
        guard requested.requiresSyncedRulebook else { return requested }
        let unresolved = usedSymbols.filter { !syncedSymbols.contains($0) }
        // Fall back to writing the constraints out, not to symbols-plus-legend.
        //
        // The legend was the wrong target: it emits every symbol AND its full
        // definition, so it costs strictly more than simply writing the
        // constraint as a sentence — measured at 218 tokens against 190 on the
        // same prompt. The downgrade fires precisely when the user has not
        // synced a rulebook, which is the common case, so the safety net was
        // quietly handing most users the most expensive mode of all.
        //
        // Writing the constraints out is cheaper and no less clear: a full
        // sentence in place needs no lookup at all. That is `off`, which expands
        // every symbol in the IR.
        return unresolved.isEmpty ? requested : .off
    }

    // MARK: - Matching

    /// The symbol `candidate` states, or nil.
    static func match(_ candidate: String, in rulebook: PromptRulebook) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // The model was asked to emit symbols directly; honour that first.
        if rulebook.symbols.contains(trimmed) { return trimmed }

        let candidateTokens = tokens(of: trimmed)
        guard !candidateTokens.isEmpty else { return nil }
        let candidateNegated = isNegated(trimmed)

        var best: (symbol: String, score: Double)?
        // The best score belonging to a *different* rule. Without it, the winner
        // of a tie was whichever rule the stdlib happens to declare first.
        var runnerUp: Double = 0
        for rule in rulebook.rules {
            for target in rule.matchTargets {
                // Token overlap is blind to polarity: "add new dependencies"
                // and "do not add new dependencies" share almost every token.
                // Requiring the polarity to agree is what stops the compressor
                // from inverting a constraint's meaning.
                guard isNegated(target) == candidateNegated else { continue }

                let score = overlap(candidateTokens, tokens(of: target))
                guard score >= matchThreshold else { continue }
                if let current = best, current.symbol != rule.symbol {
                    // Whichever of the two ends up losing is still the best
                    // evidence for a competing rule, so both orders update it.
                    runnerUp = max(runnerUp, min(score, current.score))
                }
                if best == nil || score > best!.score {
                    best = (rule.symbol, score)
                }
            }
        }
        guard let best else { return nil }
        // Two rules explaining the sentence about equally well means the
        // sentence does not identify either one, and substituting the winner
        // puts a constraint in the prompt that the user did not state.
        // "要引用出處" scored CITE_THE_RULE and CITE_SOURCES at 1.00 and 0.50,
        // "不要留 TODO 或半成品" scored two rules at 1.00 each, and
        // "動手前先跟我說你要怎麼做" separated ASK_BEFORE_DESTRUCTIVE from
        // EXPLAIN_FIRST by 0.03 — all decided by declaration order.
        //
        // Leaving the user's own sentence in place is the cheap failure: it
        // costs tokens. The other one changes what the prompt asks for.
        guard best.score - runnerUp >= ambiguityMargin else { return nil }
        return best.symbol
    }

    /// How far the best rule must beat the second-best *different* rule.
    ///
    /// Set from the measured gaps rather than picked: correct matches in the
    /// corpus separate by 0.40–0.50, while every mis-resolution found sat at
    /// 0.03 or lower. Anything in between is genuinely ambiguous.
    static let ambiguityMargin = 0.15

    /// Latin text tokenizes on whitespace; CJK has no word spaces, so each
    /// character is its own token.
    static func tokens(of text: String) -> Set<String> {
        let stripped = text.lowercased().filter { !$0.isPunctuation && !$0.isSymbol }
        var result = Set<String>()
        var latinRun = ""

        func flushLatin() {
            if latinRun.count >= 2 { result.insert(latinRun) }
            latinRun = ""
        }

        for character in stripped {
            if TokenEstimator.isCJK(character) {
                flushLatin()
                result.insert(String(character))
            } else if character.isWhitespace {
                flushLatin()
            } else {
                latinRun.append(character)
            }
        }
        flushLatin()
        return result
    }

    /// Shared fraction of the smaller set, with a floor on the absolute overlap
    /// so a single common word ("the", "不") cannot carry a match.
    /// Tokens that carry no topic, only grammar or polarity.
    ///
    /// Excluded from the overlap because they are shared by almost every rule.
    /// Polarity is checked separately by `isNegated`, so letting "no" also count
    /// as evidence of *which* rule this is had it doing two jobs — and the
    /// second one badly.
    /// Kept deliberately small: only grammar and polarity. Words like `new`,
    /// `add` and `keep` stay informative — they are what tells `NO_DEPS` apart
    /// from `KEEP_API`, and removing them stopped the matcher recognising
    /// anything at all.
    static let uninformativeTokens: Set<String> = [
        "no", "not", "never", "dont", "doesnt", "wont", "without",
        "the", "a", "an", "any", "this", "that", "it", "to", "of", "in", "on",
        "do", "does", "did", "is", "are", "be", "or", "and",
        "不", "不要", "別", "勿", "的", "了", "這", "那",
    ]

    /// How much two phrases have in common, counting only informative tokens.
    ///
    /// The denominator is the shorter side, which makes a short rule phrase easy
    /// to match — and with function words counted, far too easy: `no new
    /// libraries` is three tokens, so sharing just `no` and `new` scored 0.67
    /// and cleared the 0.65 threshold. That is how "Stay within the stated
    /// scope: no unrelated refactors, renames, or new abstractions" was
    /// compressed to `NO_DEPS`, a rule about packages.
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let left = a.subtracting(uninformativeTokens)
        let right = b.subtracting(uninformativeTokens)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.intersection(right).count
        guard shared >= minimumSharedTokens else { return 0 }
        return Double(shared) / Double(min(left.count, right.count))
    }

    /// How many informative tokens two phrases must share to be the same rule.
    ///
    /// Also the floor on how many a *rule phrasing* needs in order to be matchable
    /// at all — see `PromptRule.deadPhrasings()`, which is what makes the
    /// consequence visible instead of leaving a listed phrasing quietly inert.
    static let minimumSharedTokens = 2

    /// The tokens of `text` that carry topic rather than grammar or polarity.
    static func informativeTokens(of text: String) -> Set<String> {
        tokens(of: text).subtracting(uninformativeTokens)
    }

    static let negationMarkers = [
        "not", "never", "no", "dont", "doesnt", "wont", "avoid", "without",
        "不", "別", "勿", "禁止", "無需", "毋須",
    ]

    /// Whether a phrase forbids rather than requires. Cheap and deliberately
    /// generous — a false positive here only costs a missed compression, while
    /// a false negative would let the matcher flip a rule's meaning.
    static func isNegated(_ text: String) -> Bool {
        // Fold apostrophes before splitting, or "don't" tokenizes to "don" +
        // "t" and the contraction reads as non-negated — exactly the mistake
        // that would let "don't add packages" match "add packages".
        let lowered = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        // Split on anything that is not a letter or a digit, rather than on
        // whitespace and punctuation. `<` and `>` are symbols, not punctuation,
        // so `<context>dont add packages` kept `<context>dont` as one token and
        // the prohibition stopped being visible the moment the output moved to
        // XML tags. Any adjacent bracket or quote had the same effect.
        let words = Set(
            lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        )
        for marker in negationMarkers {
            if marker.allSatisfy({ $0.isASCII }) {
                if words.contains(marker) { return true }
            } else if lowered.contains(marker) {
                return true
            }
        }
        return false
    }
}
