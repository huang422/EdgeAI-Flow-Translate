import XCTest
@testable import FlowTranslateCore

/// The saved-rulebook repair path.
///
/// The bug these cover: a rulebook saved before the bundled phrasings were fixed
/// keeps its stale copy forever, because `RulebookStore` prefers what is on disk.
/// The editor then reports "13 個問題" with no proportionate way to clear them —
/// the only remedy was "reset to built-in", which discards every custom rule the
/// user has written.
final class RulebookRepairTests: XCTestCase {

    /// A rule whose only fault is a phrasing the matcher can never reach.
    private func staleRule() -> PromptRule {
        var rule = PromptStdlib.all.rule(for: "NO_DEPS")!
        rule.match = ["no new dependencies", "no deps"]  // "no deps" is one token.
        return rule
    }

    func testTheBundledRulebookIsClean() {
        // If this fails, the repair has nothing correct to repair *towards*.
        XCTAssertEqual(PromptStdlib.all.validationErrors(), [])
        XCTAssertTrue(PromptStdlib.all.invalidRuleIDs.isEmpty)
    }

    func testDeadPhrasingIsReplacedByTheBundledWording() {
        let book = PromptRulebook(rules: [staleRule()])
        XCTAssertFalse(book.validationErrors().isEmpty)

        let repaired = book.repairingPhrasings(using: PromptStdlib.all)
        XCTAssertEqual(repaired.validationErrors(), [])
        let match = repaired.rule(for: "NO_DEPS")!.match
        XCTAssertFalse(match.contains("no deps"))
        // The bundled phrasings are pulled in, so the rule still matches speech.
        XCTAssertFalse(match.isEmpty)
        XCTAssertTrue(match.contains(where: PromptStdlib.all.rule(for: "NO_DEPS")!.match.contains))
    }

    func testAUsersOwnPhrasingSurvivesTheRepair() {
        var rule = staleRule()
        rule.match = ["no deps", "不要拉新的套件進來"]
        let repaired = PromptRulebook(rules: [rule]).repairingPhrasings(using: PromptStdlib.all)
        XCTAssertTrue(repaired.rule(for: "NO_DEPS")!.match.contains("不要拉新的套件進來"))
    }

    func testARuleTheReferenceDoesNotKnowKeepsItsLivePhrasings() {
        var rule = staleRule()
        rule.symbol = "TEAM_ONLY_RULE"
        rule.aliases = []
        rule.match = ["ship it", "always run the smoke suite first"]
        let repaired = PromptRulebook(rules: [rule]).repairingPhrasings(using: PromptStdlib.all)
        let match = repaired.rule(for: "TEAM_ONLY_RULE")!.match
        XCTAssertEqual(match, ["always run the smoke suite first"])
    }

    func testRepairLeavesEverythingElseAlone() {
        let book = PromptRulebook(rules: [staleRule()])
        let repaired = book.repairingPhrasings(using: PromptStdlib.all)
        let before = book.rules[0], after = repaired.rules[0]
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(before.symbol, after.symbol)
        XCTAssertEqual(before.description, after.description)
        XCTAssertEqual(before.source, after.source)
        XCTAssertEqual(before.backends, after.backends)
    }

    func testUnrepairableIssuesAreNotOffered() {
        // A missing source is a problem no automatic repair can fix, and the
        // editor must not show a button that would leave the count unchanged.
        var rule = PromptStdlib.all.rule(for: "MIN_DIFF")!
        rule.source = ""
        let book = PromptRulebook(rules: [rule])
        XCTAssertFalse(book.validationErrors().isEmpty)
        XCTAssertFalse(book.issuesAreRepairable)
    }

    func testRepairableIssuesAreOffered() {
        XCTAssertTrue(PromptRulebook(rules: [staleRule()]).issuesAreRepairable)
    }

    func testInvalidRuleIDsNamesOnlyTheOffenders() {
        let good = PromptStdlib.all.rule(for: "MIN_DIFF")!
        let bad = staleRule()
        let book = PromptRulebook(rules: [good, bad])
        XCTAssertEqual(book.invalidRuleIDs, [bad.id])
    }
}

/// Reconciling a saved rulebook with a newer bundled one.
///
/// The store was write-once-read-forever: the first save froze that install's
/// rules and every later improvement to the bundled library reached nobody. It
/// showed up twice in use — thirteen phrasings that had already been fixed still
/// reported as problems, and new `WEB_SEARCH` phrasings never matched.
final class RulebookUpgradeTests: XCTestCase {

    /// What an old install has: the current rules, no version, no edit flags.
    private func staleBook() -> PromptRulebook {
        var book = PromptStdlib.all
        book.stdlibVersion = 0
        for index in book.rules.indices where book.rules[index].symbol == "WEB_SEARCH" {
            book.rules[index].match = ["search the web", "上網搜尋"]   // the old, narrow list
        }
        return book
    }

    func testAnUntouchedRuleIsRefreshedFromTheBundle() {
        let upgraded = PromptRulebook.upgrading(staleBook(), to: PromptStdlib.all)
        let match = upgraded.rule(for: "WEB_SEARCH")!.match
        XCTAssertEqual(match, PromptStdlib.all.rule(for: "WEB_SEARCH")!.match)
        XCTAssertTrue(match.contains("search online"))
    }

    /// From version 1 on the flag is recorded at save time, so an edit is known
    /// rather than guessed — and survives.
    func testAFlaggedEditSurvivesTheUpgrade() {
        var book = staleBook()
        book.stdlibVersion = 1
        let index = book.rules.firstIndex { $0.symbol == "WEB_SEARCH" }!
        book.rules[index].match = ["我的說法"]
        book.rules[index].description = "My own wording."
        book.rules[index].isUserEdited = true

        let upgraded = PromptRulebook.upgrading(book, to: PromptRulebook(
            rules: PromptStdlib.all.rules, stdlibVersion: PromptStdlib.version + 1
        ))
        XCTAssertEqual(upgraded.rule(for: "WEB_SEARCH")!.match, ["我的說法"])
        XCTAssertEqual(upgraded.rule(for: "WEB_SEARCH")!.description, "My own wording.")
    }

    /// The one thing the version-0 migration cannot do, stated so it is a
    /// decision rather than a surprise: a book saved before edits were tracked
    /// carries no record of them, and inferring them from the current bundle
    /// would preserve every stale rule. Bundled symbols are taken from the app.
    func testAnUnflaggedEditToABundledRuleIsReplaced() {
        var book = staleBook()          // version 0
        let index = book.rules.firstIndex { $0.symbol == "WEB_SEARCH" }!
        book.rules[index].match = ["我的說法"]

        let upgraded = PromptRulebook.upgrading(book, to: PromptStdlib.all)
        XCTAssertEqual(upgraded.rule(for: "WEB_SEARCH")!.match,
                       PromptStdlib.all.rule(for: "WEB_SEARCH")!.match)
    }

    func testAUserAddedRuleSurvivesTheUpgrade() {
        var book = staleBook()
        book.rules.append(PromptRule(
            symbol: "TEAM_RULE", match: ["always run the smoke suite"],
            description: "Run the team's smoke suite.", source: "Team handbook"
        ))
        let upgraded = PromptRulebook.upgrading(book, to: PromptStdlib.all)
        XCTAssertNotNil(upgraded.rule(for: "TEAM_RULE"))
        XCTAssertEqual(upgraded.rules.count, PromptStdlib.all.rules.count + 1)
        // Recorded now, so the next upgrade does not have to guess again.
        XCTAssertTrue(upgraded.rule(for: "TEAM_RULE")!.isUserEdited)
    }

    func testTheUpgradeClearsTheStaleIssues() {
        var book = staleBook()
        let index = book.rules.firstIndex { $0.symbol == "NO_DEPS" }!
        book.rules[index].match = ["no deps"]   // one informative token: unmatchable
        XCTAssertFalse(book.validationErrors().isEmpty)

        // Not user-edited in any way they would recognise, so the bundle wins.
        let upgraded = PromptRulebook.upgrading(book, to: PromptStdlib.all)
        XCTAssertEqual(upgraded.validationErrors(), [])
    }

    func testAnUpToDateBookIsLeftAlone() {
        let current = PromptStdlib.all
        XCTAssertEqual(PromptRulebook.upgrading(current, to: current), current)
    }

    func testStampingMarksOnlyWhatChanged() {
        var book = PromptStdlib.all
        let index = book.rules.firstIndex { $0.symbol == "MIN_DIFF" }!
        book.rules[index].description = "changed"
        let stamped = book.stampingUserEdits(against: PromptStdlib.all)
        XCTAssertEqual(stamped.rules.filter(\.isUserEdited).map(\.symbol), ["MIN_DIFF"])
    }
}
