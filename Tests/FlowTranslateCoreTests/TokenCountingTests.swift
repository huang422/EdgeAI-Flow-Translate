import Foundation
import Testing
@testable import FlowTranslateCore

private struct StubCounter: TokenCounting {
    var answers: [String: Int]
    func count(_ text: String) -> Int? { answers[text] }
}

@Suite("Token counting")
struct TokenCountingTests {

    @Test("a real tokenizer's answer is used and marked exact")
    func exactCountsWin() {
        let meter = TokenMeter(counter: StubCounter(answers: ["hello world": 2]))
        let count = meter.count("hello world")
        #expect(count.value == 2)
        #expect(count.source == .modelTokenizer)
        #expect(count.source.isExact)
    }

    /// The fallback must be silent in behaviour and loud in labelling: the user
    /// sees a number either way, but never an estimate presented as exact.
    @Test("an unavailable tokenizer falls back to the heuristic, labelled")
    func fallbackIsLabelled() {
        let meter = TokenMeter(counter: StubCounter(answers: [:]))
        let count = meter.count("hello world")
        #expect(count.value == TokenEstimator.estimate("hello world"))
        #expect(count.source == .heuristic)
        #expect(!count.source.isExact)
    }

    @Test("no counter at all still produces a number")
    func heuristicOnlyWorks() {
        let count = TokenMeter().count("hello world")
        #expect(count.value > 0)
        #expect(count.source == .heuristic)
    }

    /// The one number in this feature that must never flatter by accident. If
    /// the two ends were measured differently, part of the "saving" would be the
    /// change of method rather than a change of text.
    /// A pair is exact only when BOTH ends are. The cache behind the model
    /// counter evicts entries independently, so one end hitting and the other
    /// missing is routine — and labelling that pair "measured" drops the `≈`
    /// from a ratio that is half guess.
    @Test("a half-cached comparison is reported as an estimate")
    func mixedProvenanceIsNotClaimedExact() {
        let meter = TokenMeter(counter: StubCounter(answers: ["aaaa aaaa aaaa": 3]))
        let comparison = meter.compare(before: "aaaa aaaa aaaa", after: "bbbb")
        #expect(comparison.source == .heuristic)
        #expect(comparison.summary.contains("≈"))
    }

    @Test("a fully cached comparison is reported as exact")
    func bothEndsExactIsExact() {
        let meter = TokenMeter(counter: StubCounter(answers: ["aaa": 3, "b": 1]))
        let comparison = meter.compare(before: "aaa", after: "b")
        #expect(comparison.source == .modelTokenizer)
        #expect(!comparison.summary.contains("≈"))
    }

    @Test("only estimates are hedged with ≈")
    func hedgingMatchesProvenance() {
        let estimated = TokenComparison(before: 100, after: 60, source: .heuristic)
        let exact = TokenComparison(before: 100, after: 60, source: .modelTokenizer)
        #expect(estimated.summary.contains("≈"))
        #expect(!exact.summary.contains("≈"))
        #expect(exact.summary == "100 → 60 (−40%)")
    }

    @Test("growth is reported as growth")
    func inflationIsNotHidden() {
        let grew = TokenComparison(before: 50, after: 75, source: .modelTokenizer)
        #expect(grew.savedPercent == -50)
        #expect(grew.summary.contains("+50%"))
    }
}
