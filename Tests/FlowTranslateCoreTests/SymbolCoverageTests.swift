import Foundation
import Testing
@testable import FlowTranslateCore

/// Every symbol has to be reachable, resolvable and renderable. A rule that
/// cannot be produced from the words a user would actually say is a rule that
/// does not exist, and the failure is silent — the constraint simply stays a
/// sentence and nobody knows a symbol was available.
///
/// Written as an exhaustive sweep rather than a hand-picked list. The hand-picked
/// list covered six of fifty-two, which is how eleven rules could be
/// unreachable-by-design for as long as they were.
@Suite("Every symbol is usable")
struct SymbolCoverageTests {

    private var book: PromptRulebook { PromptStdlib.all }

    /// The matcher must recognise every phrasing the rule advertises. These are
    /// the strings the rulebook editor shows a user as "say this and you get
    /// this symbol".
    @Test("every advertised phrasing resolves to its own rule")
    func everyMatchPhraseResolves() {
        var failures: [String] = []
        for rule in book.rules {
            for phrase in rule.match {
                let resolved = SymbolCompressor.match(phrase, in: book)
                if resolved != rule.symbol {
                    failures.append("\(rule.symbol) ← \"\(phrase)\" resolved to \(resolved ?? "nothing")")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Each alternate identifier has to reach the same rule, or a user who wrote
    /// `API_STABLE` in their own rulebook gets nothing.
    @Test("every alias reaches its rule")
    func everyAliasResolves() {
        for rule in book.rules {
            for alias in rule.aliases {
                #expect(book.rule(for: alias)?.symbol == rule.symbol, "\(alias)")
            }
        }
    }

    /// The end-to-end check: the phrase goes in, the symbol comes out of the
    /// renderer. `match` succeeding is not enough — `compress` can still decline
    /// to emit it, which is exactly what happened to the eleven counter-intuitive
    /// rules for as long as they were exempt.
    @Test("every rule can actually appear as a symbol in a rendered prompt")
    func everyRuleCanBeEmitted() {
        var missing: [String] = []
        for rule in book.rules {
            guard let phrase = rule.match.first else {
                missing.append("\(rule.symbol) has no match phrasing at all")
                continue
            }
            let rendered = PromptRenderer.render(
                PromptIR(goal: "Do the thing", constraints: [phrase]),
                options: PromptRenderOptions(
                    symbolMode: .symbolsAssumeRulebook,
                    syncedSymbols: Set(book.symbols)
                )
            )
            if !rendered.usedSymbols.contains(rule.symbol) {
                missing.append("\(rule.symbol) ← \"\(phrase)\"")
            }
        }
        #expect(missing.isEmpty, "never emitted as a symbol:\n\(missing.joined(separator: "\n"))")
    }

    /// A symbol in a prompt is only meaningful if the file written to the project
    /// defines it. This is the write/read round-trip that decides whether bare
    /// symbols are honest at all.
    @Test("every symbol survives the rulebook round-trip")
    func everySymbolRoundTrips() {
        let artifact = PromptRenderer.renderRulebook(book, language: .english)
        var defined = PromptRenderer.parseSymbols(from: artifact.content)
        for companion in artifact.companions {
            defined.formUnion(PromptRenderer.parseSymbols(from: companion.content))
        }
        #expect(defined == book.symbols, "missing: \(book.symbols.subtracting(defined))")
    }

    /// No rule may render as an empty string in either language or for either
    /// agent — a blank bullet is a constraint that silently disappeared.
    @Test("every rule renders in both languages and for both agents")
    func everyRuleRendersEverywhere() {
        for rule in book.rules {
            for backend in [RuleBackend.claude, .codex, .generic] {
                for language in PromptOutputLanguage.allCases {
                    let text = rule.expansion(for: backend, language: language)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    #expect(!text.isEmpty, "\(rule.symbol) \(backend) \(language)")
                }
            }
        }
    }

    /// The library must not contain two rules a user could reasonably mean by the
    /// same words: whichever wins is arbitrary, and the other is unreachable.
    @Test("no two rules claim the same phrasing")
    func phrasingsAreUnambiguous() {
        var owner: [String: String] = [:]
        var clashes: [String] = []
        for rule in book.rules {
            for phrase in rule.match {
                let key = phrase.lowercased()
                if let existing = owner[key], existing != rule.symbol {
                    clashes.append("\"\(phrase)\" claimed by \(existing) and \(rule.symbol)")
                }
                owner[key] = rule.symbol
            }
        }
        #expect(clashes.isEmpty, "\(clashes.joined(separator: "\n"))")
    }

    @Test("the library itself validates")
    func libraryIsValid() {
        #expect(book.validationErrors().isEmpty, "\(book.validationErrors())")
    }
}

/// The invariant behind the sweep above, stated so a new rule cannot reintroduce
/// the failure: a phrasing whose informative content is one token can never
/// clear the matcher's two-token floor, so listing it in the editor as "say this"
/// is a promise the matcher cannot keep.
@Suite("Phrasings are matchable by construction")
struct PhrasingViabilityTests {

    @Test("no shipped phrasing is dead on arrival")
    func noDeadPhrasings() {
        let dead = PromptStdlib.all.rules.flatMap { rule in
            rule.deadPhrasings().map { "\(rule.symbol): \"\($0)\"" }
        }
        #expect(dead.isEmpty, "\(dead.joined(separator: "\n"))")
    }

    /// The check itself has to be right, or it passes vacuously.
    @Test("the check recognises a one-token phrasing")
    func detectorWorks() {
        let rule = PromptRule(
            symbol: "TEST_RULE",
            match: ["deterministic", "no eval", "keep tests deterministic"],
            description: "d", source: "s"
        )
        #expect(rule.deadPhrasings() == ["deterministic", "no eval"])
        #expect(!rule.validationErrors().isEmpty)
    }

    /// And the floor is what makes it necessary: widening the matcher instead
    /// would resolve "run the eval suite" to NO_EVAL in a project whose evals are
    /// the subject.
    @Test("a single shared word is not a match")
    func oneSharedWordDoesNotMatch() {
        #expect(SymbolCompressor.match("run the eval suite", in: PromptStdlib.all) != "NO_EVAL")
    }
}
