import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct AgentsFileRendererTests {

    private let book = PromptRulebook(rules: Array(PromptStdlib.all.rules.prefix(3)))

    // MARK: - The invariant that matters
    //
    // AGENTS.md is the user's file. Unlike `.claude/rules/`, which this app owns
    // outright, everything outside the managed block must survive untouched.

    @Test func contentOutsideTheBlockSurvivesByteForByte() {
        let original = """
        # AGENTS.md

        ## Setup commands
        - Install deps: `pnpm install`

        ## Code style
        - TypeScript strict mode
        """
        let merged = AgentsFileRenderer.merge(book, into: original)
        #expect(merged.contains("- Install deps: `pnpm install`"))
        #expect(merged.contains("- TypeScript strict mode"))
        #expect(merged.hasPrefix("# AGENTS.md"))
    }

    @Test func mergingIsIdempotent() {
        let original = "# AGENTS.md\n\n## Setup\n- Run `make`\n"
        let once = AgentsFileRenderer.merge(book, into: original)
        let twice = AgentsFileRenderer.merge(book, into: once)
        #expect(once == twice)
    }

    @Test func rulebookChangesReplaceOnlyTheBlock() {
        let original = "# AGENTS.md\n\n## Setup\n- Run `make`\n"
        let first = AgentsFileRenderer.merge(book, into: original)
        let bigger = PromptRulebook(rules: Array(PromptStdlib.all.rules.prefix(6)))
        let second = AgentsFileRenderer.merge(bigger, into: first)

        #expect(second.contains("- Run `make`"))
        // Exactly one managed block, not two appended copies.
        #expect(second.components(separatedBy: AgentsFileRenderer.startMarker).count == 2)
        #expect(second.components(separatedBy: AgentsFileRenderer.endMarker).count == 2)
    }

    @Test func userContentStaysFirstWhenTheBlockIsAppended() {
        let original = "# AGENTS.md\n\n## Setup\n- Run `make`\n"
        let merged = AgentsFileRenderer.merge(book, into: original)
        let userIndex = merged.range(of: "## Setup")!.lowerBound
        let blockIndex = merged.range(of: AgentsFileRenderer.startMarker)!.lowerBound
        #expect(userIndex < blockIndex)
    }

    @Test func aTruncatedBlockDoesNotSwallowTrailingContent() {
        // A start marker with no end marker means the file was hand-edited or
        // cut short. Replacing to end-of-file would delete what followed.
        let damaged = """
        # AGENTS.md

        \(AgentsFileRenderer.startMarker)
        (an end marker used to be here)

        ## Important user section
        - Do not lose me
        """
        let merged = AgentsFileRenderer.merge(book, into: damaged)
        #expect(merged.contains("- Do not lose me"))
        #expect(merged.contains("## Important user section"))
    }

    @Test func creatingFromNothingProducesAValidFile() {
        let created = AgentsFileRenderer.merge(book, into: nil)
        #expect(created.hasPrefix("# AGENTS.md"))
        #expect(AgentsFileRenderer.containsManagedBlock(created))

        let fromBlank = AgentsFileRenderer.merge(book, into: "   \n  ")
        #expect(fromBlank.hasPrefix("# AGENTS.md"))
    }

    // MARK: - Round trip

    @Test func symbolsCanBeReadBackFromTheBlock() {
        // Same safety-critical loop as `.claude/rules/`: if reading stopped
        // matching writing, bare-symbol mode would silently never engage.
        let merged = AgentsFileRenderer.merge(book, into: "# AGENTS.md\n")
        #expect(AgentsFileRenderer.symbols(in: merged) == book.symbols)
    }

    @Test func symbolsOutsideTheBlockAreNotCounted() {
        // A user writing **NO_DEPS** in their own prose has not defined it.
        let text = "# AGENTS.md\n\nWe try to avoid **NO_DEPS** situations.\n"
        #expect(AgentsFileRenderer.symbols(in: text).isEmpty)
    }

    // MARK: - Backend wording

    @Test func theBlockUsesCodexWordingNotClaudeWording() {
        let codex = AgentsFileRenderer.merge(book, into: nil, backend: .codex)
        let claude = AgentsFileRenderer.merge(book, into: nil, backend: .claude)
        #expect(codex != claude)
        #expect(codex.contains("No new third-party dependencies."))
    }

    @Test func rulesAreGroupedByCategory() {
        let full = AgentsFileRenderer.merge(PromptStdlib.all, into: nil)
        #expect(full.contains("### Coding"))
        #expect(full.contains("### Security"))
    }

    @Test func pathScopedRulesAreExcludedFromTheSharedBlock() {
        // `AGENTS.md` has no equivalent of `paths` frontmatter, so a scoped rule
        // would silently become unconditional — more context on every task.
        let scoped = PromptRulebook(rules: [
            PromptRule(symbol: "SWIFT_STYLE", description: "Four-space indent.",
                       source: "test", paths: ["**/*.swift"]),
        ])
        #expect(AgentsFileRenderer.merge(scoped, into: nil).contains("SWIFT_STYLE") == false)
    }

    // MARK: - Bridge

    @Test func claudeBridgeImportsAgentsFile() {
        #expect(AgentsFileRenderer.claudeBridge.hasPrefix("@AGENTS.md"))
    }
}
