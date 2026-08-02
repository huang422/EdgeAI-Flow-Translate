import XCTest
@testable import FlowTranslateCore

final class CaptionBandStateTests: XCTestCase {

    private let u1 = UUID(), u2 = UUID(), u3 = UUID()
    private let k1 = UUID(), k2 = UUID(), k3 = UUID()

    // MARK: - Interim → in-place commit (the anti-jump core)

    func testInterimCreatesSlot() {
        var band = CaptionBandState(historyLimit: 1)
        band.interim(utteranceId: u1, source: .system, english: "hello", chinese: nil, expectsTranslation: true)
        XCTAssertEqual(band.slot?.id, u1)
        XCTAssertEqual(band.slot?.english, "hello")
        XCTAssertFalse(band.slot?.isFinal ?? true)
    }

    func testInterimUpdatesSameSlotIdentity() {
        var band = CaptionBandState(historyLimit: 1)
        band.interim(utteranceId: u1, source: .system, english: "hello", chinese: nil, expectsTranslation: true)
        band.interim(utteranceId: u1, source: .system, english: "hello world", chinese: "哈囉", expectsTranslation: true)
        XCTAssertEqual(band.slot?.id, u1)                       // identity stable → no view jump
        XCTAssertEqual(band.slot?.english, "hello world")
        XCTAssertEqual(band.slot?.chinese, "哈囉")
    }

    func testCommitMorphsSlotInPlace() {
        var band = CaptionBandState(historyLimit: 1)
        band.interim(utteranceId: u1, source: .system, english: "so um hello world", chinese: nil, expectsTranslation: true)
        band.commit(utteranceId: u1, source: .system,
                    sentences: [(key: k1, english: "So hello world.")], expectsTranslation: true)
        XCTAssertEqual(band.slot?.id, u1)                       // SAME identity after finalize
        XCTAssertEqual(band.slot?.english, "So hello world.")   // cleaned text morphed in
        XCTAssertEqual(band.slot?.translationKey, k1)
        XCTAssertTrue(band.slot?.isFinal ?? false)
        XCTAssertTrue(band.committed.isEmpty)                   // nothing rolled up yet
    }

    func testMultiSentenceCommitKeepsLastInSlot() {
        var band = CaptionBandState(historyLimit: 2)
        band.interim(utteranceId: u1, source: .system, english: "a b c", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u1, source: .system,
                    sentences: [(k1, "First."), (k2, "Second."), (k3, "Third.")], expectsTranslation: false)
        XCTAssertEqual(band.committed.map(\.english), ["First.", "Second."])
        XCTAssertEqual(band.slot?.english, "Third.")
        XCTAssertEqual(band.slot?.id, u1)
    }

    // MARK: - Roll-up on next utterance

    func testNewUtteranceRollsUpFinalizedSlot() {
        var band = CaptionBandState(historyLimit: 2)
        band.interim(utteranceId: u1, source: .system, english: "one", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "One.")], expectsTranslation: false)
        // The finalized sentence stays in the slot until the NEXT utterance starts.
        band.interim(utteranceId: u2, source: .system, english: "two", chinese: nil, expectsTranslation: false)
        XCTAssertEqual(band.committed.map(\.english), ["One."])
        XCTAssertEqual(band.slot?.id, u2)
        XCTAssertEqual(band.slot?.english, "two")
    }

    func testUnfinalizedSlotIsReplacedNotRolledUp() {
        var band = CaptionBandState(historyLimit: 2)
        band.interim(utteranceId: u1, source: .system, english: "half a sent", chinese: nil, expectsTranslation: false)
        band.interim(utteranceId: u2, source: .microphone, english: "mic talks", chinese: nil, expectsTranslation: false)
        XCTAssertTrue(band.committed.isEmpty)                   // interim never enters history
        XCTAssertEqual(band.slot?.id, u2)
    }

    func testHistoryEviction() {
        var band = CaptionBandState(historyLimit: 1)
        band.interim(utteranceId: u1, source: .system, english: "1", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "One.")], expectsTranslation: false)
        band.interim(utteranceId: u2, source: .system, english: "2", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u2, source: .system, sentences: [(k2, "Two.")], expectsTranslation: false)
        band.interim(utteranceId: u3, source: .system, english: "3", chinese: nil, expectsTranslation: false)
        XCTAssertEqual(band.committed.map(\.english), ["Two."])   // "One." evicted
        XCTAssertEqual(band.slot?.english, "3")
    }

    // MARK: - Background-source commit

    func testBackgroundCommitInsertsIntoHistory() {
        var band = CaptionBandState(historyLimit: 2)
        band.interim(utteranceId: u1, source: .system, english: "video talks", chinese: nil, expectsTranslation: false)
        // Mic utterance finalizes but was never the displayed interim.
        band.commit(utteranceId: nil, source: .microphone,
                    sentences: [(k1, "Mic sentence.")], expectsTranslation: false)
        XCTAssertEqual(band.committed.map(\.english), ["Mic sentence."])
        XCTAssertEqual(band.slot?.english, "video talks")       // slot untouched
        XCTAssertFalse(band.slot?.isFinal ?? true)
    }

    func testBackgroundCommitRollsUpFinalizedSlotFirst() {
        var band = CaptionBandState(historyLimit: 3)
        band.interim(utteranceId: u1, source: .system, english: "one", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "One.")], expectsTranslation: false)
        band.commit(utteranceId: nil, source: .microphone, sentences: [(k2, "Mic.")], expectsTranslation: false)
        // Chronological: One. then Mic. — and the slot is free.
        XCTAssertEqual(band.committed.map(\.english), ["One.", "Mic."])
        XCTAssertNil(band.slot)
    }

    // MARK: - Translation routing

    func testTranslationRoutesToSlotAndHistory() {
        var band = CaptionBandState(historyLimit: 2)
        band.interim(utteranceId: u1, source: .system, english: "a", chinese: nil, expectsTranslation: true)
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "First."), (k2, "Second.")], expectsTranslation: true)
        band.translation(key: k1, text: "第一句。")
        band.translation(key: k2, text: "第二句。")
        XCTAssertEqual(band.committed.first?.chinese, "第一句。")
        XCTAssertEqual(band.slot?.chinese, "第二句。")
    }

    func testInterimTranslationOnlyTouchesLiveSlot() {
        var band = CaptionBandState(historyLimit: 1)
        band.interim(utteranceId: u1, source: .system, english: "a", chinese: nil, expectsTranslation: true)
        band.interimTranslation(utteranceId: u1, text: "甲")
        XCTAssertEqual(band.slot?.chinese, "甲")
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "A.")], expectsTranslation: true)
        band.interimTranslation(utteranceId: u1, text: "乙")   // finalized → ignored
        XCTAssertEqual(band.slot?.chinese, "甲")
    }

    // MARK: - Discard (filler-only utterances)

    func testDiscardDropsUnfinalizedSlot() {
        var band = CaptionBandState(historyLimit: 1)
        band.interim(utteranceId: u1, source: .system, english: "um", chinese: nil, expectsTranslation: false)
        band.discard(utteranceId: u1)
        XCTAssertNil(band.slot)
        XCTAssertFalse(band.hasContent)
    }

    func testDiscardNeverTouchesFinalizedSlotOrOtherUtterance() {
        var band = CaptionBandState(historyLimit: 1)
        band.interim(utteranceId: u1, source: .system, english: "one", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "One.")], expectsTranslation: false)
        band.discard(utteranceId: u1)                          // finalized → keep
        XCTAssertEqual(band.slot?.english, "One.")
        band.interim(utteranceId: u2, source: .system, english: "two", chinese: nil, expectsTranslation: false)
        band.discard(utteranceId: u1)                          // stale id → no-op
        XCTAssertEqual(band.slot?.english, "two")
    }

    // MARK: - Pin

    func testPinFreezesDisplayAndCountsCommits() {
        var band = CaptionBandState(historyLimit: 2)
        band.interim(utteranceId: u1, source: .system, english: "one", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "One.")], expectsTranslation: false)
        band.pin()
        XCTAssertEqual(band.visibleSlot?.english, "One.")
        // Two sentences arrive while pinned.
        band.interim(utteranceId: u2, source: .system, english: "x", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u2, source: .system, sentences: [(k2, "Two."), (k3, "Three.")], expectsTranslation: false)
        XCTAssertEqual(band.pendingWhilePinned, 2)              // counts EVENTS, not array diffs
        XCTAssertEqual(band.visibleSlot?.english, "One.")       // frozen view
        XCTAssertEqual(band.slot?.english, "Three.")            // live state advanced
        band.unpin()
        XCTAssertEqual(band.pendingWhilePinned, 0)
        XCTAssertEqual(band.visibleSlot?.english, "Three.")
    }

    /// Regression: the old implementation diffed array lengths (both capped) so
    /// the badge stuck at 0 once the buffer was full. Event counting keeps going.
    func testPendingCountKeepsCountingPastHistoryLimit() {
        var band = CaptionBandState(historyLimit: 1)
        for i in 0..<8 {
            let uid = UUID()
            band.interim(utteranceId: uid, source: .system, english: "s\(i)", chinese: nil, expectsTranslation: false)
            band.commit(utteranceId: uid, source: .system, sentences: [(UUID(), "S\(i).")], expectsTranslation: false)
        }
        band.pin()
        for i in 8..<14 {
            let uid = UUID()
            band.interim(utteranceId: uid, source: .system, english: "s\(i)", chinese: nil, expectsTranslation: false)
            band.commit(utteranceId: uid, source: .system, sentences: [(UUID(), "S\(i).")], expectsTranslation: false)
        }
        XCTAssertEqual(band.pendingWhilePinned, 6)
    }

    // MARK: - Lifecycle

    func testClearResetsEverything() {
        var band = CaptionBandState(historyLimit: 2)
        band.interim(utteranceId: u1, source: .system, english: "a", chinese: nil, expectsTranslation: false)
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "A.")], expectsTranslation: false)
        band.pin()
        band.clear()
        XCTAssertFalse(band.hasContent)
        XCTAssertFalse(band.isPinned)
        XCTAssertNil(band.latestFinal)
    }

    func testLatestFinalPrefersFinalizedSlot() {
        var band = CaptionBandState(historyLimit: 2)
        band.interim(utteranceId: u1, source: .system, english: "a", chinese: nil, expectsTranslation: false)
        XCTAssertNil(band.latestFinal)                           // interim isn't copyable
        band.commit(utteranceId: u1, source: .system, sentences: [(k1, "A.")], expectsTranslation: false)
        XCTAssertEqual(band.latestFinal?.english, "A.")
    }
}
