import Foundation

/// What kind of request this is. A `refine` already has a prompt to improve, a
/// `new` one starts from a spoken description — the renderer frames them
/// differently.
public enum PromptTaskType: String, Codable, Sendable, CaseIterable {
    case new
    case refine
    case port
    case debug
}

/// How a referenced file should reach Claude.
public enum ReferenceLoadMode: String, Codable, Sendable {
    /// Named by repo-relative path; Claude decides whether to read it. The
    /// default, and the single largest token saving available in a coding
    /// prompt — pasting a file costs its whole length every single time.
    case referenced
    /// Content genuinely has to be inline (Claude cannot reach the file).
    case loaded
    /// Named only so Claude knows to stay out of it.
    case outOfScope

    /// Decodes leniently: a model asked for `referenced` may answer `"ref"`,
    /// `"reference"` or `"out of scope"`.
    init(lenient raw: String) {
        let normalized = raw.lowercased().filter { $0.isLetter }
        switch normalized {
        case let s where s.hasPrefix("load") || s.hasPrefix("inline"): self = .loaded
        case let s where s.contains("outofscope") || s.contains("exclude"): self = .outOfScope
        default: self = .referenced
        }
    }
}

/// One file, directory or URL the task touches.
public struct PromptReference: Codable, Sendable, Equatable, Hashable {
    public var path: String
    public var loadMode: ReferenceLoadMode
    /// Optional one-liner on why it matters. Dropped when empty.
    public var note: String?

    public init(path: String, loadMode: ReferenceLoadMode = .referenced, note: String? = nil) {
        self.path = path
        self.loadMode = loadMode
        self.note = note
    }

    // A model prompted for objects will sometimes emit bare strings anyway, so
    // accept both shapes rather than losing the whole field to one bad answer.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let path = try? single.decode(String.self) {
            self.init(path: path)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = (try? container.decode(String.self, forKey: .path)) ?? ""
        let rawMode = (try? container.decode(String.self, forKey: .loadMode)) ?? "referenced"
        let note = try? container.decode(String.self, forKey: .note)
        self.init(
            path: path,
            loadMode: ReferenceLoadMode(lenient: rawMode),
            note: (note?.isEmpty ?? true) ? nil : note
        )
    }
}

/// The Prompt AST: a structured request, independent of how it will be
/// rendered. Every downstream stage — optimization, symbolic compression, all
/// four output backends — reads this and nothing else.
///
/// The field set mirrors the "capture contract" used by Sentry's production
/// `prompt-optimizer` skill (objective, non-goals, hard constraints, required
/// output shape, success criteria, failure cases, inputs/tools/files), which is
/// independent confirmation that these are the things worth pinning down.
///
/// Decoding is deliberately tolerant in exactly the way `CaptionSettings` is:
/// a local 4B model will occasionally emit a string where a list belongs, or
/// invent a field. A single such slip should cost that one field, never the
/// whole compile.
public struct PromptIR: Codable, Sendable, Equatable {
    public var taskType: PromptTaskType
    /// One imperative sentence, verb first: the work to do. Empty when the
    /// request only asks something.
    public var goal: String
    /// What the request asks, kept as a question.
    ///
    /// A **separate axis** from `goal`, not an alternative to it. This started as
    /// a `taskType` case, which forced every request to be either a question or a
    /// task — and real requests are routinely both: "為何字幕會跳動？順便把
    /// finalize 修好" asks something *and* asks for work. With one field the
    /// second half was silently dropped, or the question was rewritten as an
    /// instruction, depending on which way the classifier fell.
    ///
    /// Either may be empty. Both empty is the only unusable state, which is what
    /// `isActionable` checks.
    public var question: String
    /// The separate pieces of work, in order, when the request contains more than
    /// one.
    ///
    /// A long request routinely holds several distinct tasks — "change the
    /// renderer, let the user pick a mode, drop the JSON, and make the tests
    /// pass" is four — and a single `goal` sentence could only ever carry the
    /// first. The rest leaked into `context` and `acceptance`, where they read as
    /// background rather than work, or were dropped.
    ///
    /// Rendered as a numbered list, which is what Anthropic's prompting guide
    /// asks for directly: "provide instructions as sequential steps using
    /// numbered lists or bullet points when the order or completeness of steps
    /// matters". Completeness is exactly what is at stake — the failure mode this
    /// field exists for is the last requirement going missing.
    public var steps: [String]
    /// Background facts. Not instructions.
    public var context: [String]
    /// Rules the work must obey.
    public var constraints: [String]
    /// What explicitly must *not* happen. The most valuable section for recent
    /// Claude models, which otherwise tend to widen a task's scope.
    public var scopeExclusions: [String]
    /// The concrete artifacts to produce.
    public var deliverables: [String]
    /// Checkable conditions for "done".
    public var acceptance: [String]
    /// Known ways this goes wrong.
    public var failureCases: [String]
    public var references: [PromptReference]
    public var suggestedTools: [String]

    public init(
        taskType: PromptTaskType = .new,
        goal: String = "",
        question: String = "",
        steps: [String] = [],
        context: [String] = [],
        constraints: [String] = [],
        scopeExclusions: [String] = [],
        deliverables: [String] = [],
        acceptance: [String] = [],
        failureCases: [String] = [],
        references: [PromptReference] = [],
        suggestedTools: [String] = []
    ) {
        self.taskType = taskType
        self.goal = goal
        self.question = question
        self.steps = steps
        self.context = context
        self.constraints = constraints
        self.scopeExclusions = scopeExclusions
        self.deliverables = deliverables
        self.acceptance = acceptance
        self.failureCases = failureCases
        self.references = references
        self.suggestedTools = suggestedTools
    }

    /// The IR reduced to what `detail` will actually print.
    ///
    /// Applied **before** symbolic compression, not after, and that ordering is
    /// the whole point: compressing first computes `usedSymbols`, the legend, the
    /// sync hint and `effectiveMode` from constraints that never reach the output,
    /// so a symbol appearing only inside a dropped `out_of_scope` downgrades the
    /// entire prompt and the UI advises syncing to shorten text that is not there.
    ///
    /// Every section is gated the same way, by `PromptDetailLevel.includes` —
    /// never by content, which would put the level rule in two places that have to
    /// agree by hand.
    public func visible(at detail: PromptDetailLevel) -> PromptIR {
        var result = self
        if !detail.includes(.scopeExclusions) { result.scopeExclusions = [] }
        if !detail.includes(.failureCases) { result.failureCases = [] }
        if !detail.includes(.tools) { result.suggestedTools = [] }
        return result
    }

    // Declared explicitly rather than synthesized: `stringList` names
    // `CodingKeys` in its signature, and a static member referring to the type
    // blocks the compiler from inferring it.
    enum CodingKeys: String, CodingKey {
        case taskType, goal, question, steps, context, constraints, scopeExclusions
        case deliverables, acceptance, failureCases, references, suggestedTools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = (try? container.decode(String.self, forKey: .taskType)) ?? ""
        self.taskType = PromptTaskType(rawValue: rawType.lowercased()) ?? .new
        let rawGoal = ((try? container.decode(String.self, forKey: .goal)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawQuestion = ((try? container.decode(String.self, forKey: .question)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A model that answered the older single-axis schema — `taskType:
        // "question"` with the question in `goal` — is read the way it meant it.
        // The two fields are a different shape, not a different vocabulary, and
        // losing a whole compile to that would be the tolerant decode failing at
        // the one thing it exists for.
        if rawQuestion.isEmpty, rawType.lowercased() == "question" {
            self.goal = ""
            self.question = rawGoal
        } else {
            self.goal = rawGoal
            self.question = rawQuestion
        }
        self.steps = Self.stringList(container, .steps)
        self.context = Self.stringList(container, .context)
        self.constraints = Self.stringList(container, .constraints)
        self.scopeExclusions = Self.stringList(container, .scopeExclusions)
        self.deliverables = Self.stringList(container, .deliverables)
        self.acceptance = Self.stringList(container, .acceptance)
        self.failureCases = Self.stringList(container, .failureCases)
        self.suggestedTools = Self.stringList(container, .suggestedTools)
        self.references = ((try? container.decode([PromptReference].self, forKey: .references)) ?? [])
            .filter { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Accepts `["a", "b"]`, `"a"`, and a missing key — all three happen.
    private static func stringList(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [String] {
        var raw: [String] = []
        if let list = try? container.decode([String].self, forKey: key) {
            raw = list
        } else if let single = try? container.decode(String.self, forKey: key) {
            raw = [single]
        }
        return normalize(raw)
    }

    /// Trim, drop blanks, and remove exact repeats while keeping order. Near-
    /// duplicates are `PromptOptimizer`'s job; this only removes noise that
    /// would otherwise be measured as content.
    static func normalize(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Whether there is enough here to render anything useful.
    public var isActionable: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the request asks for an answer at all.
    public var asksAQuestion: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The questions, separately.
    ///
    /// One dictated breath routinely contains several: "task 跟 question 怎麼分
    /// 的？為何只會出現一種？" is two, and rendering them as one run-on line asks
    /// the reader to find the boundaries — which is exactly the work the tags
    /// exist to have already done. Numbered, an answer can address each in turn,
    /// and a missed one is visible.
    ///
    /// A sentence that is **not** itself a question attaches to the question that
    /// follows it, rather than becoming an item of its own. Questions carry
    /// setup — "字幕會跳動。為什麼？" is one question with a premise, not a
    /// statement plus a question — and splitting them strands the premise as a
    /// numbered item that asks nothing. Trailing non-questions stay with the last
    /// item for the same reason.
    public var questions: [String] {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sentences = SentenceSplitter.split(trimmed).filter { !$0.isEmpty }
        guard sentences.count > 1 else { return [trimmed] }

        var grouped: [String] = []
        var pending: [String] = []
        for sentence in sentences {
            pending.append(sentence)
            guard QuestionDetector.isQuestion(sentence) else { continue }
            grouped.append(pending.joined(separator: " "))
            pending = []
        }
        if !pending.isEmpty {
            // Whatever is left asked nothing. Append it to the previous question
            // instead of dropping it — it is still something the user said.
            if grouped.isEmpty {
                grouped = [pending.joined(separator: " ")]
            } else {
                grouped[grouped.count - 1] += " " + pending.joined(separator: " ")
            }
        }
        return grouped
    }

    /// Whether the request asks for work at all.
    public var asksForWork: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A question with no work attached: the case where acting at all is wrong.
    public var isPureQuestion: Bool { asksAQuestion && !asksForWork }

    /// Every bullet across the sections, for measuring and linting.
    public var allBullets: [String] {
        (question.isEmpty ? [] : [question])
            + steps + context + constraints + scopeExclusions
            + deliverables + acceptance + failureCases
    }
}
