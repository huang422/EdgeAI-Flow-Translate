import Foundation

/// Which Claude Code surface an artifact targets.
///
/// These are not interchangeable formats of the same thing — each has a
/// different *loading* model, which decides what belongs in it:
///
/// - `.rules` loads at every session start, so it holds durable definitions.
/// - `.skill` loads on demand when Claude judges it relevant, so it holds a
///   repeatable workflow.
/// - `.command` loads when the user types `/name`.
/// - `.prompt` is used immediately and never installed.
public enum PromptArtifactKind: String, Sendable, Equatable, CaseIterable, Identifiable {
    case prompt
    case skill
    case command
    case rules

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .prompt: return "Prompt（剪貼簿）"
        case .skill: return "Skill（.claude/skills）"
        case .command: return "Slash command（.claude/commands）"
        case .rules: return "規則本（.claude/rules）"
        }
    }
}

/// A file that ships alongside the main artifact — the `references/*.md` half
/// of a progressively-disclosed skill.
public struct PromptArtifactCompanion: Sendable, Equatable {
    public let relativePath: String
    public let content: String

    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

/// A rendered, ready-to-use output.
public struct PromptArtifact: Sendable, Equatable {
    public let kind: PromptArtifactKind
    public let content: String
    /// Where this belongs inside a project, using forward slashes. `nil` for
    /// clipboard-only output.
    public let relativePath: String?
    /// Symbols the content actually uses — drives rulebook syncing and the
    /// safety downgrade when a symbol would be undefined.
    public let usedSymbols: [String]
    /// Symbols the compressor recognised but the target project cannot resolve,
    /// so they were written out in full instead.
    ///
    /// Kept separate from `usedSymbols`, which by then is empty, because "no
    /// symbols appear in this prompt" has two completely different causes:
    /// nothing in the request matched a rule, or something did and the project
    /// has no rulebook to define it. Only the second is worth telling the user
    /// about — syncing changes nothing in the first — and the UI had no way to
    /// tell them apart, so the "sync to shorten your constraints" nudge appeared
    /// on prompts that syncing could not shorten.
    public let unresolvedSymbols: [String]
    public let companions: [PromptArtifactCompanion]

    public init(
        kind: PromptArtifactKind,
        content: String,
        relativePath: String? = nil,
        usedSymbols: [String] = [],
        unresolvedSymbols: [String] = [],
        companions: [PromptArtifactCompanion] = []
    ) {
        self.kind = kind
        self.content = content
        self.relativePath = relativePath
        self.usedSymbols = usedSymbols
        self.unresolvedSymbols = unresolvedSymbols
        self.companions = companions
    }

    /// Approximate token cost of what Claude will actually read. Companions are
    /// excluded on purpose: they load only if Claude follows the reference, so
    /// counting them would overstate the per-use cost.
    public var estimatedTokens: Int { TokenEstimator.estimate(content) }
}
