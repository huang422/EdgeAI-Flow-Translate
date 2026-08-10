import Foundation

/// Where the raw request text came from. Decides whether the spoken-noise
/// cleaner runs at all: typed text has no hesitation sounds to strip, and
/// running a spoken filter over it only risks eating something deliberate.
public enum PromptInputOrigin: String, Codable, Sendable {
    case speech
    case typed
    /// Dictated first, then edited by hand — treated as speech, because the
    /// dictated portion still carries fillers.
    case mixed

    public var needsSpokenCleanup: Bool { self != .typed }
}

/// Language of the compiled prompt — not of the user's input, which is always
/// accepted in either language.
///
/// English is the default because it is measurably cheaper: the same constraint
/// costs roughly 30–50% more tokens in Chinese (see `TokenEstimator`'s
/// per-class ratios), Claude follows English instructions most consistently,
/// and the identifiers in a repository are English anyway.
public enum PromptOutputLanguage: String, Codable, Sendable, CaseIterable, Identifiable {

    case english = "en"
    case traditionalChinese = "zh-Hant"

    public var id: String { rawValue }

    /// Settings saved when a third "follow the input" option existed decode to
    /// English — the default, and the cheaper of the two.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PromptOutputLanguage(rawValue: raw) ?? .english
    }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        }
    }

    /// The language to write in.
    ///
    /// Both cases are explicit, so this is the identity — kept as a function
    /// because call sites read better asking for the resolved value than
    /// assuming there is nothing to resolve.
    public func resolved(for input: String) -> PromptOutputLanguage { self }
}

/// How rulebook symbols (`NO_DEPS`) appear in the compiled prompt.
///
/// The whole risk of symbolic compression is a prompt that references a symbol
/// the target project never defined — Claude can only guess at that. These
/// modes trade compression against that risk, and the default is the safe one.
/// How rulebook constraints appear in the compiled prompt.
///
/// Three modes, in increasing order of how much the rulebook is trusted to speak
/// for you — and, apart from the legend, decreasing token cost. Measured on one
/// two-constraint prompt: 55 / 83 / 24 tokens.
///
/// Three and not four: an `expandInline` mode ("改寫成完整規則") between `off` and
/// the symbol modes renders the **same bytes** as `off` for every prompt this app
/// can show. Any mode other than `off` puts the rulebook in the compiler's system
/// prompt, so the model returns constraints already written as symbols — and from
/// a symbol-laden IR, "keep my wording" and "use the rulebook's wording" both have
/// to expand those symbols into identical text.
public enum PromptSymbolMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Your own phrasing. The rulebook is not used to rewrite it — but a symbol
    /// that reached the IR anyway is still written out in full, so no prompt
    /// ships an identifier its reader cannot resolve.
    case off
    /// Symbols, with a definition list appended so a reader who has never seen
    /// the rulebook can still resolve them. Costs the most of the four on a
    /// single prompt; pays off only if the same symbols recur.
    case symbolsWithLegend
    /// Bare symbols. The cheapest, and honest only once the rulebook is on disk
    /// in the target project.
    case symbolsAssumeRulebook

    public var id: String { rawValue }

    /// Maps the retired `expandInline` onto the mode that replaced it.
    ///
    /// A stored setting outlives the case that wrote it. Without this, everyone
    /// who had chosen it would be silently moved to `symbolsAssumeRulebook` (the
    /// default the lenient decoder falls back to) — bare symbols, which is the
    /// one mode that needs a synced rulebook to be honest. Landing on `off` keeps
    /// what they were actually getting.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let known = PromptSymbolMode(rawValue: raw) {
            self = known
            return
        }
        // Only the one retired name is translated. Anything else is genuinely
        // unknown and must still throw, so `CaptionSettings`'s lenient decode
        // applies the app default rather than this silently answering for it.
        guard raw == "expandInline" else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown PromptSymbolMode `\(raw)`."
            )
        }
        self = .off
    }

    /// Names the behaviour rather than the mechanism. "Expand inline" and
    /// "Symbols only" described the implementation to someone who already knew
    /// how it worked, which is not the person reading a picker.
    public var displayName: String {
        switch self {
        case .off: return "原句不動 Keep my wording"
        case .symbolsWithLegend: return "符號＋對照表 Symbols + legend"
        case .symbolsAssumeRulebook: return "純符號 Symbols only"
        }
    }

    public var shortName: String { displayName }

    /// One line saying what you get and what it costs.
    public var explanation: String {
        switch self {
        case .off:
            return "Your own sentences, spelled out in full. Needs nothing in the project, and "
                + "reads the same to an agent that has never heard of the rulebook."
        case .symbolsWithLegend:
            return "Constraints become NO_DEPS, with a definition list appended. Readable by "
                + "anyone, but the most expensive of the four on a single prompt."
        case .symbolsAssumeRulebook:
            return "Just NO_DEPS — the project's rules file supplies the definition. Cheapest; "
                + "needs the rulebook synced first."
        }
    }

    /// Whether this mode emits bare symbols the reader must already understand.
    public var requiresSyncedRulebook: Bool { self == .symbolsAssumeRulebook }
}

/// What the global dictation hotkey drops at the cursor.
///
/// Three, because two was a false choice. The gap between "the raw recognizer
/// output" and "a fully structured agent prompt" is most of what people dictate:
/// a message, a commit body, a note. `tidied` is that middle — the sentences you
/// said, with the mis-hearings and the punctuation fixed, and nothing added.
///
/// It is also the **default**, for the same reason. A global dictation hotkey
/// fires in every application, and most of those are not a coding agent: pressing
/// it in Slack and getting a prompt full of `<task>` tags is a surprise, where
/// getting your own sentence spelled correctly is what anyone would expect. The
/// compiled prompt is a deliberate choice, one click away on the panel itself.
public enum PromptQuickInsertMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Run the full compile. Higher quality, several seconds.
    case compiledPrompt
    /// Repair the dictation and insert that: same sentences, spelled correctly.
    /// One model pass over the whole passage, no restructuring.
    case tidiedTranscript
    /// Insert the raw transcript. No LLM, sub-second — the escape hatch when
    /// latency matters more than anything.
    case rawTranscript

    public var id: String { rawValue }

    /// Named for the buttons that do the same thing: the Prompt page's actions
    /// are 編譯 Compile · 口述 Dictate · 整理 Tidy · 清除 Clear, and a picker a few
    /// points away must not use a different word for the same operation.
    public var displayName: String {
        switch self {
        case .compiledPrompt: return "AI 提示詞 Prompt"
        case .tidiedTranscript: return "整理 Tidy"
        case .rawTranscript: return "原文 Raw"
        }
    }

    /// The label the HUD shows — short enough for a 320 pt panel.
    public var shortName: String {
        switch self {
        case .compiledPrompt: return "Prompt"
        case .tidiedTranscript: return "Tidy"
        case .rawTranscript: return "Raw"
        }
    }

    public var explanation: String {
        switch self {
        case .compiledPrompt:
            return "編譯成給編碼代理的完整 prompt（標籤、約束、檔案路徑）。含整理，所以最慢。"
        case .tidiedTranscript:
            return "你講的句子，修好錯字、同音字、標點與斷句，說錯改口的部分只留改正後的版本。"
                + "不會增加任何內容，也不會重新編排。適合訊息、commit、筆記。"
        case .rawTranscript:
            return "辨識到什麼就插入什麼，一個字都不改。最快，也是用來對照 Tidied 改了什麼的依據。"
        }
    }

    /// Whether this mode needs the Qwen model at all.
    public var needsLanguageModel: Bool { self != .rawTranscript }
}

/// How much of a compiled prompt to print.
///
/// Two levels, and the line between them is one question: **did the request say
/// it, or did this tool produce it?** Everything the user said survives at both.
///
/// Measured on a representative compiled prompt (181 tokens total):
///
/// | Section | Tokens | Where the content comes from |
/// |---|---|---|
/// | `task` (+ steps) | 42 | the request |
/// | `out_of_scope` | 25 | the request, **or** injected by the linter |
/// | `context` | 24 | the request |
/// | `files` | 18 | the request, verified |
/// | `constraints` | 15 | the request |
/// | `done_when` | 12 | the request |
/// | `output` | 11 | the request |
/// | `risks` | 10 | the model, inferred |
/// | `tools` | 7 | the model, inferred |
///
/// `out_of_scope` is gated by *content*, not by section: `PromptIR.visible(at:)`
/// drops only `PromptOptimizer.defaultScopeExclusion`, the line the linter writes
/// when the request named no boundary. A user who says "不要動到 public API" and
/// gets a prompt without it has been failed in the one way a prompt compiler
/// cannot afford.
///
/// `files` stays at both levels because its paths are verified against the
/// request text, and dropping them is how an agent ends up guessing where the
/// code is. `done_when` and `output` cost ~6% together and each removes a
/// checkable completion condition, so neither is gated.
public enum PromptDetailLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    /// What the request contained. The default.
    case compact
    /// Also prints the sections this tool inferred.
    case full

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: return "精簡 Compact"
        case .full: return "完整 Full"
        }
    }

    /// One short English line. The tag list beside it in the UI says the rest,
    /// and says it in the vocabulary the output actually uses.
    public var explanation: String {
        switch self {
        case .compact: return "What you asked for. Drops out_of_scope, risks and tools."
        case .full: return "Everything, including the review boundary, risks and tools."
        }
    }

    /// Whether a section survives at this level.
    ///
    /// **The one place the two levels differ**, and deliberately the only one: a
    /// second content filter inside `PromptIR.visible(at:)` would be two rules for
    /// one question, and the levels have to stay tellable apart.
    ///
    /// Three sections are `full`-only, and they are exactly the three the
    /// compiler produces rather than the user:
    ///
    /// | Section | Tag | Why it is `full`-only |
    /// |---|---|---|
    /// | `scopeExclusions` | `out_of_scope` | a review boundary, most often the linter's own default line |
    /// | `failureCases` | `risks` | inferred by the model, nobody asked for it |
    /// | `tools` | `tools` | inferred by the model |
    ///
    /// Everything else comes from the request and prints at both.
    ///
    /// Note the trade this makes: a boundary the user *did* state out loud —
    /// "不要動到 public API" — is compiled into `scopeExclusions` and therefore
    /// only appears at `full`. `constraints` is where a stated requirement
    /// belongs and is never gated, so the way to keep such a line at `compact` is
    /// to phrase it as a constraint.
    public func includes(_ section: PromptSectionKind) -> Bool {
        switch section {
        case .task, .question, .answerFirst, .context, .deliverables,
             .constraints, .acceptance, .references:
            return true
        case .scopeExclusions, .failureCases, .tools:
            return self == .full
        }
    }
}

/// The sections a rendered prompt can contain.
///
/// Deliberately separate from `IRSection`, which the linter switches over
/// exhaustively to apply fixes. That enum is about the fields a fix can edit;
/// this one is about the blocks a prompt can print, and they are not the same
/// list — `references` and `tools` are printable but not fixable, and `goal` is
/// fixable but never optional.
public enum PromptSectionKind: String, Sendable, CaseIterable {
    case task
    case question
    case answerFirst
    case context
    case deliverables
    case constraints
    case scopeExclusions
    case acceptance
    case failureCases
    case references
    case tools
}
