import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct PromptStdlibTests {

    @Test func everyRuleIsValid() {
        let errors = PromptStdlib.all.validationErrors()
        #expect(errors.isEmpty, "stdlib has invalid rules: \(errors)")
    }

    @Test func everyRuleCitesASource() {
        // The line between a standard library and a list of opinions. A rule
        // nobody can trace is a rule nobody should be asked to follow.
        for rule in PromptStdlib.all.rules {
            #expect(
                rule.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "\(rule.symbol) has no source"
            )
        }
    }

    @Test func everyCategoryIsPopulated() {
        for category in RuleCategory.allCases {
            #expect(PromptStdlib.category(category).count >= 5,
                    "\(category.rawValue) has too few rules")
        }
    }

    @Test func symbolsAndAliasesAreGloballyUnique() {
        var seen = Set<String>()
        for rule in PromptStdlib.all.rules {
            #expect(seen.insert(rule.symbol).inserted, "duplicate symbol \(rule.symbol)")
            for alias in rule.aliases {
                #expect(seen.insert(alias).inserted, "alias \(alias) collides")
            }
        }
    }

    @Test func everyRuleHasBilingualMatchPhrases() {
        // Both languages must resolve to the same rule, or a user who switches
        // language mid-thought gets inconsistent output.
        for rule in PromptStdlib.all.rules {
            let hasLatin = rule.match.contains { $0.contains(where: { $0.isASCII && $0.isLetter }) }
            // Presence, not dominance: "commit 格式" is a perfectly good Chinese
            // phrasing even though most of its characters are Latin.
            let hasCJK = rule.match.contains { $0.contains(where: TokenEstimator.isCJK) }
            #expect(hasLatin, "\(rule.symbol) has no English match phrase")
            #expect(hasCJK, "\(rule.symbol) has no Chinese match phrase")
        }
    }

    // MARK: - Backend expansion

    @Test func expansionFallsBackRatherThanReturningEmpty() {
        let rule = PromptRule(
            symbol: "X", description: "Fallback description.",
            backends: [.generic: "Generic wording."], source: "test"
        )
        #expect(rule.expansion(for: .claude) == "Generic wording.")   // backend → generic
        let bare = PromptRule(symbol: "Y", description: "Only a description.", source: "test")
        #expect(bare.expansion(for: .codex) == "Only a description.") // generic → description
    }

    @Test func backendWordingDiffersWhereItShould() {
        guard let keepAPI = PromptStdlib.all.rule(for: "KEEP_API") else {
            Issue.record("KEEP_API missing"); return
        }
        #expect(keepAPI.expansion(for: .claude) != keepAPI.expansion(for: .codex))
        #expect(keepAPI.expansion(for: .claude, language: .traditionalChinese).contains("公開 API"))
    }

    @Test func alternateIdentifiersResolveToTheSameRule() {
        let book = PromptStdlib.all
        #expect(book.rule(for: "API_STABLE")?.symbol == "KEEP_API")
        #expect(book.rule(for: "NO_BREAKING_CHANGE")?.symbol == "KEEP_API")
    }

    // MARK: - Encoding

    @Test func rulebookRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(PromptStdlib.all)
        let decoded = try JSONDecoder().decode(PromptRulebook.self, from: data)
        #expect(decoded.symbols == PromptStdlib.all.symbols)
        #expect(decoded.rule(for: "KEEP_API")?.backends[.codex] != nil)
    }

    @Test func unknownBackendKeysAreDroppedNotFatal() throws {
        let json = #"""
        {"rules":[{"symbol":"X","description":"d","source":"s",
          "backends":{"claude":"c","some-future-agent":"f"}}]}
        """#
        let book = try JSONDecoder().decode(PromptRulebook.self, from: Data(json.utf8))
        #expect(book.rules.count == 1)
        #expect(book.rules[0].backends[.claude] == "c")
        #expect(book.rules[0].backends.count == 1)
    }

    @Test func validationCatchesAnUnsourcedRule() {
        let book = PromptRulebook(rules: [
            PromptRule(symbol: "NO_SOURCE", description: "Something.", source: "")
        ])
        #expect(book.validationErrors().contains { $0.contains("no source") })
    }
}
