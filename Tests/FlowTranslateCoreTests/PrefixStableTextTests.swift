import XCTest
@testable import FlowTranslateCore

final class PrefixStableTextTests: XCTestCase {

    // MARK: - First candidate

    func testFirstCandidateShowsImmediately() {
        var t = PrefixStableText()
        XCTAssertEqual(t.update(candidate: "我想要"), "我想要")
    }

    func testEmptyCandidateIsIgnored() {
        var t = PrefixStableText()
        XCTAssertEqual(t.update(candidate: "   "), "")
        XCTAssertEqual(t.update(candidate: "你好"), "你好")
    }

    // MARK: - Monotonic growth (the whole point)

    func testAgreeingCandidatesExtendDisplay() {
        var t = PrefixStableText()
        t.update(candidate: "我想要去")
        // Second candidate shares the prefix and extends it.
        XCTAssertEqual(t.update(candidate: "我想要去商店"), "我想要去")
        // Third agrees with second → stable prefix grows.
        XCTAssertEqual(t.update(candidate: "我想要去商店買"), "我想要去商店")
    }

    func testHeadRewriteFreezesDisplay() {
        var t = PrefixStableText(conflictLimit: 3)
        t.update(candidate: "我想要去")
        // Retranslation reorders the head ("我明天想去…") → conflict → freeze.
        XCTAssertEqual(t.update(candidate: "我明天想去商店"), "我想要去")
        XCTAssertEqual(t.update(candidate: "我明天想去商店"), "我想要去")
    }

    func testDisplayNeverRewritesHeadWhileGrowing() {
        var t = PrefixStableText()
        var previous = ""
        for cand in ["我想", "我想要", "我想要去商", "我想要去商店買東西"] {
            let shown = t.update(candidate: cand)
            XCTAssertTrue(shown.hasPrefix(previous), "\(shown) should extend \(previous)")
            previous = shown
        }
    }

    // MARK: - Conflict resync

    func testPersistentConflictResyncsOnce() {
        var t = PrefixStableText(conflictLimit: 3)
        t.update(candidate: "我想要去")
        XCTAssertEqual(t.update(candidate: "明天我想去商店"), "我想要去")   // conflict 1
        XCTAssertEqual(t.update(candidate: "明天我想去商店"), "我想要去")   // conflict 2
        // Third consecutive conflict → resync to the latest candidate.
        XCTAssertEqual(t.update(candidate: "明天我想去商店買菜"), "明天我想去商店買菜")
    }

    func testAgreementResetsConflictCounter() {
        var t = PrefixStableText(conflictLimit: 2)
        t.update(candidate: "我想要去")
        _ = t.update(candidate: "明天想去")                 // conflict 1
        _ = t.update(candidate: "明天想去商店")             // stable extends lastCandidate…
        // LCP(明天想去, 明天想去商店) = 明天想去 → doesn't prefix "我想要去" → conflict 2 → resync
        XCTAssertEqual(t.displayed, "明天想去商店")
    }

    // MARK: - Commit

    func testCommitAlwaysWins() {
        var t = PrefixStableText()
        t.update(candidate: "我想要去")
        t.update(candidate: "我想要去商店")
        XCTAssertEqual(t.commit("我明天想去商店。"), "我明天想去商店。")
        XCTAssertEqual(t.displayed, "我明天想去商店。")
    }

    func testResetClearsEverything() {
        var t = PrefixStableText()
        t.update(candidate: "hello there")
        t.reset()
        XCTAssertEqual(t.displayed, "")
        XCTAssertEqual(t.update(candidate: "next utterance"), "next utterance")
    }

    // MARK: - Word-boundary snapping (spaced scripts)

    func testLatinPrefixSnapsToWordBoundary() {
        // "I want to compute" vs "I want to computer…" share "I want to compu"
        // mid-word — the stable prefix must fall back to "I want to".
        let p = PrefixStableText.stablePrefix("I want to compute this", "I want to computer science")
        XCTAssertEqual(p, "I want to")
    }

    func testCJKPrefixKeepsPerCharacter() {
        let p = PrefixStableText.stablePrefix("我想要去商店", "我想要去學校")
        XCTAssertEqual(p, "我想要去")
    }

    func testIdenticalCandidates() {
        let p = PrefixStableText.stablePrefix("same text", "same text")
        XCTAssertEqual(p, "same text")
    }

    func testNoCommonPrefix() {
        XCTAssertEqual(PrefixStableText.stablePrefix("abc", "xyz"), "")
    }
}
