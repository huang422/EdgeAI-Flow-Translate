import Foundation

/// Which list of the IR a finding or fix applies to.
public enum IRSection: String, Sendable, Equatable, CaseIterable {
    case goal, question, steps, context, constraints, scopeExclusions, deliverables, acceptance, failureCases
}

/// A named problem the linter can recognize.
public enum LintRule: String, Sendable, Equatable, CaseIterable {
    case aggressiveEmphasis
    case selfVerificationRequest
    case chainOfThoughtRequest
    case personaWithoutBehaviour
    case missingScopeExclusions
    case vagueAcceptance
    case unlocatableReference
    case contradictoryConstraints
    case decorativeMarkup
}

/// A concrete, replayable edit. Findings carry data rather than closures so the
/// UI can list them, the user can pick some, and tests can assert on them.
public enum LintAction: Sendable, Equatable {
    case removeBullet(section: IRSection, text: String)
    case replaceBullet(section: IRSection, text: String, with: String)
    case addExclusion(String)
    /// Needs a human decision — shown, never auto-applied.
    case advisory
}

public struct LintFinding: Sendable, Equatable, Identifiable {
    public let rule: LintRule
    public let message: String
    public let offending: String?
    public let action: LintAction

    /// Includes the message, because `rule` + `offending` is not unique.
    ///
    /// One contradictory bullet can conflict with several others, producing two
    /// findings whose rule and offending text are identical and whose messages
    /// differ. The same collision happens whenever one bullet appears in two IR
    /// sections, which `SymbolCompressor` can produce — `TEST_PASS` in both
    /// constraints and acceptance. SwiftUI's `ForEach` over an `Identifiable`
    /// collection then warns and renders the rows wrongly.
    public var id: String { "\(rule.rawValue)|\(offending ?? "")|\(message)" }

    public var isAutoFixable: Bool { action != .advisory }

    public init(rule: LintRule, message: String, offending: String? = nil, action: LintAction) {
        self.rule = rule
        self.message = message
        self.offending = offending
        self.action = action
    }
}

/// The deterministic half of the compiler: everything between the model's JSON
/// and the rendered prompt.
///
/// Two jobs, both pure value logic. `optimize` shortens without changing
/// meaning. `lint` finds wording that makes recent Claude models behave worse,
/// and reports it as suggestions rather than rewriting silently — a prompt is
/// the user's, and a linter that edits it behind their back is a liability.
public enum PromptOptimizer {

    // MARK: - Optimize

    /// Shorten every field losslessly. Ordering, symbol substitution and
    /// section layout happen later in `PromptRenderer`.
    ///
    /// `request` is the text the IR was compiled from. Pass it whenever it is
    /// available: it is the only thing that can tell a file the user named from
    /// one the model invented, and the invented ones are copied verbatim out of
    /// the compiler's own few-shot examples.
    public static func optimize(
        _ ir: PromptIR, repoRoot: String? = nil, request: String? = nil
    ) -> PromptIR {
        var result = ir
        result.goal = tighten(ir.goal)
        // `tighten` and not `LexicalCompressor`: the leading politeness of a
        // spoken question is padding, but the words being asked about are not,
        // and pruning a question can remove the very one. `stripTerminalPeriod`
        // leaves `?` and `？` alone, so the question stays a question.
        result.question = tighten(ir.question)
        result.steps = tightenAll(ir.steps)
        result.context = tightenAll(ir.context)
        result.constraints = tightenAll(ir.constraints)
        result.scopeExclusions = tightenAll(ir.scopeExclusions)
        result.deliverables = tightenAll(ir.deliverables)
        result.acceptance = tightenAll(ir.acceptance)
        result.failureCases = tightenAll(ir.failureCases)
        result.suggestedTools = PromptIR.normalize(ir.suggestedTools)
        result.references = ir.references
            .map { reference in
                var updated = reference
                updated.path = relativizePath(reference.path, repoRoot: repoRoot)
                return updated
            }
            .filter { request == nil || wasNamed($0.path, in: request!) }
        result = dropNearDuplicates(result)
        return result
    }

    /// Whether the request actually mentions this path.
    ///
    /// The `<files>` section is the single largest token saving a coding prompt
    /// has — naming a file costs a handful of tokens where pasting it costs its
    /// whole length — but it is only worth anything if the paths are real. A 4B
    /// model given two worked examples reliably copies content out of them, so
    /// requests that named no file at all came back citing
    /// `Sources/Uploader.swift`: a path out of Example 1, in someone else's
    /// project. Claude then opens a file that has nothing to do with the task, or
    /// reports that it does not exist — either way the section that was supposed
    /// to save tokens spends them on a wrong answer.
    ///
    /// Matching is deliberately loose about *form* and strict about *substance*.
    /// Dictation loses separators ("sources uploader dot swift"), and the model
    /// legitimately reconstructs `Sources/Uploader.swift` from that — so a match
    /// on the last component is enough. What it will not accept is a path whose
    /// filename appears nowhere in what the user said.
    static func wasNamed(_ path: String, in request: String) -> Bool {
        let haystack = request.lowercased()
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if haystack.contains(trimmed) { return true }

        // The last component, with and without its extension: "Uploader.swift"
        // and "Uploader" both count as having been named.
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard !last.isEmpty else { return false }
        if haystack.contains(last) { return true }
        let stem = last.split(separator: ".").first.map(String.init) ?? last
        // Two characters is not a name. A one- or two-letter stem would match
        // almost any sentence by accident, which is the opposite of the point.
        return stem.count > 2 && haystack.contains(stem)
    }

    static func tightenAll(_ items: [String]) -> [String] {
        PromptIR.normalize(items.map(tighten))
    }

    /// Strip the padding speech adds without touching content: leading
    /// politeness, filler openers, and the terminal period a bullet does not
    /// need.
    static func tighten(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = stripLeadingHedges(result)
        result = collapseWhitespace(result)
        result = stripTerminalPeriod(result)
        return result
    }

    /// Openers that carry no instruction. Matched only as a prefix — "please"
    /// mid-sentence may well be part of the content.
    static let hedgePrefixes = [
        "i was wondering if you could ", "i'd like you to ", "i would like you to ",
        "i want you to ", "if you could ", "could you please ", "can you please ",
        "could you ", "can you ", "please ", "maybe ", "i think ",
        "我想要你", "我希望你", "我想說是不是可以", "我想說", "可不可以幫我", "可不可以",
        "可以幫我", "麻煩你", "幫我", "請你", "請幫我", "請幫忙",
        // No bare 請. Chinese has no word boundaries to respect, so a
        // single-character prefix cuts inside real words: 請求重試 became
        // 求重試. The same rule the Chinese filler list already states.
    ]

    static func stripLeadingHedges(_ text: String) -> String {
        var result = text
        var changed = true
        while changed {
            changed = false
            for prefix in hedgePrefixes {
                guard result.lowercased().hasPrefix(prefix) else { continue }
                result = String(result.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return result.isEmpty ? text : result
    }

    static func collapseWhitespace(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }

    /// A bullet does not need a full stop. Question marks and ellipses stay —
    /// they change how the line reads.
    static func stripTerminalPeriod(_ text: String) -> String {
        guard let last = text.last, last == "." || last == "。" else { return text }
        guard !text.hasSuffix("..") else { return text }
        return String(text.dropLast())
    }

    /// Absolute paths cost tokens and break the moment the repo moves.
    static func relativizePath(_ path: String, repoRoot: String?) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let root = repoRoot, !root.isEmpty {
            let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
            if result.hasPrefix(normalizedRoot) {
                result = String(result.dropFirst(normalizedRoot.count))
            }
        }
        if result.hasPrefix("./") { result = String(result.dropFirst(2)) }
        return result
    }

    /// Remove bullets that restate an earlier bullet in the same section.
    /// Exact repeats are already gone; this catches rewordings, keeping the
    /// shortest form since it costs least.
    static func dropNearDuplicates(_ ir: PromptIR) -> PromptIR {
        var result = ir
        result.steps = deduplicate(ir.steps)
        result.context = deduplicate(ir.context)
        result.constraints = deduplicate(ir.constraints)
        result.scopeExclusions = deduplicate(ir.scopeExclusions)
        result.deliverables = deduplicate(ir.deliverables)
        result.acceptance = deduplicate(ir.acceptance)
        result.failureCases = deduplicate(ir.failureCases)
        return result
    }

    static let duplicateThreshold = 0.8

    static func deduplicate(_ items: [String]) -> [String] {
        var kept: [String] = []
        for item in items {
            let itemTokens = SymbolCompressor.tokens(of: item)
            var replacedIndex: Int?
            var isDuplicate = false

            for (index, existing) in kept.enumerated() {
                let existingTokens = SymbolCompressor.tokens(of: existing)
                guard SymbolCompressor.overlap(itemTokens, existingTokens) >= duplicateThreshold,
                      SymbolCompressor.isNegated(item) == SymbolCompressor.isNegated(existing)
                else { continue }
                isDuplicate = true
                if item.count < existing.count { replacedIndex = index }
                break
            }

            if let index = replacedIndex {
                kept[index] = item
            } else if !isDuplicate {
                kept.append(item)
            }
        }
        return kept
    }

    // MARK: - Lint

    /// Wording that measurably degrades how recent Claude models behave.
    ///
    /// Sources: Anthropic's own guidance for Claude 4.6+/Opus 5 (aggressive
    /// emphasis overtriggers; explicit self-verification causes over-checking;
    /// scope expansion needs explicit exclusions), plus the failure-mode list
    /// published with Sentry's `prompt-optimizer` skill (no chain-of-thought
    /// requests, persona is not a behaviour rule, markup that does not reduce
    /// ambiguity, contradictory instructions).
    public static func lint(_ ir: PromptIR) -> [LintFinding] {
        var findings: [LintFinding] = []
        findings += emphasisFindings(ir)
        findings += phraseFindings(ir)
        findings += personaFindings(ir)
        findings += scopeFindings(ir)
        findings += vagueAcceptanceFindings(ir)
        findings += referenceFindings(ir)
        findings += contradictionFindings(ir)
        findings += markupFindings(ir)
        return findings
    }

    static let emphasisMarkers = [
        "CRITICAL:", "IMPORTANT:", "YOU MUST", "MUST ALWAYS", "AT ALL COSTS",
        "一定要", "務必", "絕對要", "千萬要",
    ]

    static func emphasisFindings(_ ir: PromptIR) -> [LintFinding] {
        bulletsWithSections(ir).compactMap { section, text in
            guard let marker = emphasisMarkers.first(where: {
                text.range(of: $0, options: .caseInsensitive) != nil
            }) else { return nil }
            let softened = tighten(
                text.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
            )
            guard !softened.isEmpty else { return nil }
            return LintFinding(
                rule: .aggressiveEmphasis,
                message: "「\(marker)」會讓新版 Claude 過度觸發；平述句反而更可靠。",
                offending: text,
                action: .replaceBullet(section: section, text: text, with: softened)
            )
        }
    }

    static let selfVerificationPhrases = [
        "double-check", "double check", "triple-check", "verify your answer",
        "check your work", "review your own", "再三檢查", "再檢查一次", "確認你的答案",
    ]
    static let chainOfThoughtPhrases = [
        "think step by step", "step-by-step reasoning", "show your reasoning",
        "think carefully before", "一步一步思考", "逐步思考", "顯示你的推理",
    ]

    static func phraseFindings(_ ir: PromptIR) -> [LintFinding] {
        bulletsWithSections(ir).compactMap { section, text in
            let lowered = text.lowercased()
            if selfVerificationPhrases.contains(where: { lowered.contains($0) }) {
                return LintFinding(
                    rule: .selfVerificationRequest,
                    message: "Claude 已內建自我驗證；明寫會造成過度檢查並拖慢執行。",
                    offending: text,
                    action: .removeBullet(section: section, text: text)
                )
            }
            if chainOfThoughtPhrases.contains(where: { lowered.contains($0) }) {
                return LintFinding(
                    rule: .chainOfThoughtRequest,
                    message: "在具備 adaptive thinking 的模型上索求思考步驟只會浪費 token。",
                    offending: text,
                    action: .removeBullet(section: section, text: text)
                )
            }
            return nil
        }
    }

    static let personaPrefixes = ["you are a ", "you are an ", "act as a ", "act as an ", "你是一位", "你是一個", "扮演"]

    static func personaFindings(_ ir: PromptIR) -> [LintFinding] {
        ir.context.compactMap { text in
            let lowered = text.lowercased()
            guard personaPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return nil }
            return LintFinding(
                rule: .personaWithoutBehaviour,
                message: "角色設定不會改變行為，只花 token。除非它真的改變輸出風格，否則刪掉。",
                offending: text,
                action: .removeBullet(section: .context, text: text)
            )
        }
    }

    /// The default discipline line added when a request names no boundaries.
    public static let defaultScopeExclusion =
        "Stay within the stated scope: no unrelated refactors, renames, or new abstractions."

    static func scopeFindings(_ ir: PromptIR) -> [LintFinding] {
        // A pure question already carries the strongest boundary there is — the
        // "answer, do not act" block the renderer emits for it. Adding "no
        // unrelated refactors" on top would be advice about work that was never
        // asked for, and it reads as though a change had been requested. A
        // request that also asks for work still gets the boundary.
        guard !ir.isPureQuestion else { return [] }
        guard ir.scopeExclusions.isEmpty, ir.isActionable else { return [] }
        return [LintFinding(
            rule: .missingScopeExclusions,
            message: "沒有寫「不要做什麼」。新版 Claude 傾向擴張任務範圍，明確的邊界是最有效的抑制。",
            offending: nil,
            action: .addExclusion(defaultScopeExclusion)
        )]
    }

    static let vagueTerms = [
        "good", "better", "nice", "clean code", "proper", "appropriate",
        "reasonable", "high quality", "robust", "elegant",
        "品質好", "寫得好", "更好", "好一點", "乾淨一點", "適當", "合理",
    ]

    static func vagueAcceptanceFindings(_ ir: PromptIR) -> [LintFinding] {
        ir.acceptance.compactMap { text in
            let lowered = text.lowercased()
            guard let term = vagueTerms.first(where: { lowered.contains($0) }) else { return nil }
            return LintFinding(
                rule: .vagueAcceptance,
                message: "「\(term)」無法驗證。改成可檢查的條件，例如某個指令要通過、某個檔案要存在。",
                offending: text,
                action: .advisory
            )
        }
    }

    static let unlocatablePhrases = [
        "the docs", "the documentation", "the readme", "the spec",
        "看一下文件", "參考文件", "相關文件", "看一下說明",
    ]

    static func referenceFindings(_ ir: PromptIR) -> [LintFinding] {
        bulletsWithSections(ir).compactMap { _, text in
            let lowered = text.lowercased()
            guard unlocatablePhrases.contains(where: { lowered.contains($0) }) else { return nil }
            // A concrete path in the same line makes it locatable after all.
            guard !text.contains("/"), !text.contains(".md") else { return nil }
            return LintFinding(
                rule: .unlocatableReference,
                message: "指涉了無法定位的文件。給 repo 相對路徑，Claude 才讀得到——而且比貼內容省 token。",
                offending: text,
                action: .advisory
            )
        }
    }

    static let contradictionThreshold = 0.7

    static func contradictionFindings(_ ir: PromptIR) -> [LintFinding] {
        let pool = ir.constraints + ir.scopeExclusions
        var findings: [LintFinding] = []
        for (index, first) in pool.enumerated() {
            let firstTokens = SymbolCompressor.tokens(of: first)
            for second in pool.dropFirst(index + 1) {
                let secondTokens = SymbolCompressor.tokens(of: second)
                guard SymbolCompressor.overlap(firstTokens, secondTokens) >= contradictionThreshold,
                      SymbolCompressor.isNegated(first) != SymbolCompressor.isNegated(second)
                else { continue }
                findings.append(LintFinding(
                    rule: .contradictoryConstraints,
                    message: "與「\(second)」互相矛盾。Claude 會任選一條——請自行裁決保留哪個。",
                    offending: first,
                    action: .advisory
                ))
            }
        }
        return findings
    }

    static func markupFindings(_ ir: PromptIR) -> [LintFinding] {
        bulletsWithSections(ir).compactMap { section, text in
            let stripped = text
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "###", with: "")
                .filter { !$0.unicodeScalars.contains { scalar in scalar.properties.isEmoji && scalar.value > 0x238C } }
            // Only whitespace tidying here — running the full `tighten` would
            // also strip hedges and terminal periods, and report those as
            // "decorative markup", which they are not.
            let cleaned = collapseWhitespace(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned != text, !cleaned.isEmpty else { return nil }
            return LintFinding(
                rule: .decorativeMarkup,
                message: "裝飾性標記無助於消歧，只是額外 token。",
                offending: text,
                action: .replaceBullet(section: section, text: text, with: cleaned)
            )
        }
    }

    /// Every linted string, including the goal.
    ///
    /// Including the goal: it is the most load-bearing field in the IR, and
    /// excluding it leaves `CRITICAL:` and "think step by step" — the exact
    /// wording the linter exists to remove — surviving in the one place it matters
    /// most.
    /// Apply every mechanical fix, repeatedly, until nothing is left to fix.
    ///
    /// One pass is not enough. Findings are computed against a single snapshot,
    /// and each application invalidates the `text` the others were matched on —
    /// so a goal reading "CRITICAL: think step by step and …" had the emphasis
    /// marker stripped and the chain-of-thought request left behind, because by
    /// the time that finding was applied its target string no longer existed.
    ///
    /// Bounded rather than `while`: each round must remove something to continue,
    /// but a bound makes termination a property of this function rather than of
    /// every present and future lint rule.
    public static func autoFix(_ ir: PromptIR) -> (ir: PromptIR, remaining: [LintFinding]) {
        var current = ir
        for _ in 0..<4 {
            let findings = lint(current)
            let fixable = findings.filter(\.isAutoFixable)
            guard !fixable.isEmpty else { return (current, findings) }
            let next = apply(fixable, to: current)
            if next == current { return (current, findings.filter { !$0.isAutoFixable }) }
            current = next
        }
        return (current, lint(current).filter { !$0.isAutoFixable })
    }

    /// Remove the phrases the linter flags, leaving the rest of the sentence.
    ///
    /// Used where deleting the whole string is not an option — the goal. Without
    /// it, a goal containing "think step by step" would be deleted outright and
    /// the prompt would have no task.
    static func stripPhrases(from text: String) -> String {
        var result = text
        for phrase in selfVerificationPhrases + chainOfThoughtPhrases {
            result = result.replacingOccurrences(
                of: phrase, with: "", options: [.caseInsensitive]
            )
        }
        return result
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^[,，、;；:：\\s]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bulletsWithSections(_ ir: PromptIR) -> [(IRSection, String)] {
        (ir.goal.isEmpty ? [] : [(IRSection.goal, ir.goal)])
            // Linted like the goal, and for the same reason: on a pure question
            // this is the single load-bearing field, and it is copied from the
            // user's own words — which is exactly where "CRITICAL:" and "think
            // step by step" come from.
            + (ir.question.isEmpty ? [] : [(IRSection.question, ir.question)])
            + ir.steps.map { (IRSection.steps, $0) }
            + ir.context.map { (IRSection.context, $0) }
            + ir.constraints.map { (IRSection.constraints, $0) }
            + ir.scopeExclusions.map { (IRSection.scopeExclusions, $0) }
            + ir.deliverables.map { (IRSection.deliverables, $0) }
            + ir.acceptance.map { (IRSection.acceptance, $0) }
            + ir.failureCases.map { (IRSection.failureCases, $0) }
    }

    // MARK: - Applying fixes

    /// Apply the chosen findings. Order-independent and idempotent: applying
    /// the same set twice yields the same IR.
    public static func apply(_ findings: [LintFinding], to ir: PromptIR) -> PromptIR {
        var result = ir
        for finding in findings {
            switch finding.action {
            case let .removeBullet(section, text):
                mutate(&result, section) { $0.filter { $0 != text } }
            case let .replaceBullet(section, text, replacement):
                mutate(&result, section) { bullets in
                    PromptIR.normalize(bullets.map { $0 == text ? replacement : $0 })
                }
            case let .addExclusion(text):
                if !result.scopeExclusions.contains(text) {
                    result.scopeExclusions.append(text)
                }
            case .advisory:
                continue
            }
        }
        return result
    }

    private static func mutate(
        _ ir: inout PromptIR,
        _ section: IRSection,
        _ transform: ([String]) -> [String]
    ) {
        switch section {
        case .goal:
            // The goal is never removed, only cleaned. `transform` deletes a
            // matching item, which is right for a bullet and catastrophic here —
            // it would leave the prompt with no task at all. So a removal
            // targeting the goal strips the offending phrase instead.
            let cleaned = transform([ir.goal])
            let stripped = cleaned.first ?? stripPhrases(from: ir.goal)
            // Never empty. A goal made entirely of flagged wording leaves nothing
            // behind, and a prompt with no task is worse than one with a badly
            // worded task — the user can see and fix the second.
            ir.goal = stripped.isEmpty ? ir.goal : stripped
        case .question:
            // Same protection as the goal: on a pure question, deleting this
            // leaves a prompt that asks nothing.
            let cleaned = transform([ir.question])
            let stripped = cleaned.first ?? stripPhrases(from: ir.question)
            ir.question = stripped.isEmpty ? ir.question : stripped
        case .steps: ir.steps = transform(ir.steps)
        case .context: ir.context = transform(ir.context)
        case .constraints: ir.constraints = transform(ir.constraints)
        case .scopeExclusions: ir.scopeExclusions = transform(ir.scopeExclusions)
        case .deliverables: ir.deliverables = transform(ir.deliverables)
        case .acceptance: ir.acceptance = transform(ir.acceptance)
        case .failureCases: ir.failureCases = transform(ir.failureCases)
        }
    }
}
