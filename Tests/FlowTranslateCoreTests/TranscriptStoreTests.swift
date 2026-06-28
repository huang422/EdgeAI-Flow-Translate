import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct TranscriptStoreTests {
    private func makeSegment(_ session: Session, index: Int, text: String) -> TranscriptSegment {
        TranscriptSegment(
            sessionId: session.id,
            index: index,
            startTime: TimeInterval(index),
            endTime: TimeInterval(index) + 1,
            source: .system,
            sourceText: text
        )
    }

    @Test func appendAndObserve() {
        let store = InMemoryTranscriptStore()
        var changes = 0
        store.onChange = { changes += 1 }
        let session = store.beginSession(settings: .default)
        store.append(makeSegment(session, index: 0, text: "hello"))
        #expect(store.segments.count == 1)
        #expect(changes >= 2) // beginSession + append
    }

    @Test func updateTranslation() {
        let store = InMemoryTranscriptStore()
        let session = store.beginSession(settings: .default)
        let seg = makeSegment(session, index: 0, text: "hello")
        store.append(seg)
        store.updateTranslation(segmentId: seg.id, translated: "你好")
        #expect(store.segments.first?.translatedText == "你好")
    }

    @Test func endSessionSetsEndedAt() {
        let store = InMemoryTranscriptStore()
        _ = store.beginSession(settings: .default)
        store.endSession()
        #expect(store.session?.endedAt != nil)
        #expect(store.session?.isActive == false)
    }
}
