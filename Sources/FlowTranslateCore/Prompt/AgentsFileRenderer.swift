import Foundation

/// Writes the rulebook into `AGENTS.md`, the cross-tool agent instruction file.
///
/// `AGENTS.md` is an open standard stewarded by the Agentic AI Foundation under
/// the Linux Foundation: plain Markdown, no required sections, repo root, read
/// by Codex, Cursor, Copilot, Aider, Zed and others. Claude Code does **not**
/// read it — it reads `CLAUDE.md` and `.claude/rules/` — which is why the
/// rulebook is emitted to both and the two are bridged rather than duplicated.
///
/// Unlike `.claude/rules/flow-translate-symbols.md`, which this app owns
/// outright and can overwrite wholesale, `AGENTS.md` almost always contains the
/// user's own instructions. So the rules go inside a **managed block** and
/// everything outside it is returned byte-for-byte.
public enum AgentsFileRenderer {

    public static let startMarker = "<!-- flow-translate:rules:start -->"
    public static let endMarker = "<!-- flow-translate:rules:end -->"

    public static let agentsRelativePath = "AGENTS.md"
    public static let claudeBridgeRelativePath = "CLAUDE.md"

    /// The managed block, including its markers.
    public static func block(
        for rulebook: PromptRulebook,
        backend: RuleBackend = .codex,
        language: PromptOutputLanguage = .english
    ) -> String {
        var lines = [
            startMarker,
            "## Prompt rule symbols",
            "",
            "Shorthand used in prompts written by Flow Translate. When a prompt lists a",
            "symbol under `RULES`, apply the matching instruction.",
            "",
        ]
        for category in RuleCategory.allCases {
            let rules = rulebook.rules(in: category).filter { $0.paths.isEmpty }
            guard !rules.isEmpty else { continue }
            lines.append("### \(category.rawValue.capitalized)")
            for rule in rules {
                lines.append("- **\(rule.symbol)** — \(rule.expansion(for: backend, language: language))")
            }
            lines.append("")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// Insert or replace the managed block in `existing`.
    ///
    /// Idempotent: applying it twice to the same rulebook yields the same file.
    /// Content outside the markers is never inspected, reformatted or reordered.
    public static func merge(
        _ rulebook: PromptRulebook,
        into existing: String?,
        backend: RuleBackend = .codex,
        language: PromptOutputLanguage = .english
    ) -> String {
        let managed = block(for: rulebook, backend: backend, language: language)

        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A file we are creating gets a minimal header, so the result is a
            // valid AGENTS.md on its own rather than a bare fragment.
            return """
            # AGENTS.md

            Instructions for coding agents working in this repository.

            \(managed)
            """
        }

        guard let start = existing.range(of: startMarker) else {
            // Append rather than prepend: the user's own content stays first,
            // which is what they will look for when they open the file.
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            return existing + separator + managed + "\n"
        }

        // A start marker with no end marker means the file was truncated or
        // hand-edited. Replacing to end-of-file would delete whatever followed,
        // so treat the block as ending at the marker and leave the rest alone.
        guard let end = existing.range(of: endMarker, range: start.upperBound..<existing.endIndex) else {
            return existing.replacingCharacters(in: start, with: managed)
        }
        return existing.replacingCharacters(in: start.lowerBound..<end.upperBound, with: managed)
    }

    /// Whether a file already carries a managed block.
    public static func containsManagedBlock(_ text: String) -> Bool {
        text.contains(startMarker)
    }

    /// Symbols currently defined by the managed block in `text`.
    public static func symbols(in text: String) -> Set<String> {
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { return [] }
        return PromptRenderer.parseSymbols(from: String(text[start.upperBound..<end.lowerBound]))
    }

    /// A `CLAUDE.md` that simply imports `AGENTS.md`.
    ///
    /// Anthropic's own documentation recommends this when a repository already
    /// uses `AGENTS.md`: Claude Code expands `@AGENTS.md` at session start, so
    /// one set of rules serves both without being maintained twice.
    public static var claudeBridge: String {
        """
        @AGENTS.md

        <!-- Claude Code reads CLAUDE.md rather than AGENTS.md. The import above
             makes both tools read the same instructions. Add Claude-specific
             guidance below this line. -->
        """
    }
}
