import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct BilingualContextBufferTests {
    @Test func appendsAndReturnsRecent() {
        let buffer = BilingualContextBuffer(capacity: 3)
        let a = UUID(), b = UUID()
        buffer.append(id: a, source: "Hello there.")
        buffer.append(id: b, source: "How are you?")
        #expect(buffer.recent.map(\.source) == ["Hello there.", "How are you?"])
        #expect(buffer.recent.allSatisfy { $0.translation == nil })
    }

    @Test func backFillsTranslationById() {
        let buffer = BilingualContextBuffer(capacity: 3)
        let id = UUID()
        buffer.append(id: id, source: "Good morning.")
        buffer.setTranslation("早安。", for: id)
        #expect(buffer.recent.first?.translation == "早安。")
    }

    @Test func evictsOldestBeyondCapacity() {
        let buffer = BilingualContextBuffer(capacity: 2)
        let a = UUID()
        buffer.append(id: a, source: "one")
        buffer.append(id: UUID(), source: "two")
        buffer.append(id: UUID(), source: "three")
        #expect(buffer.recent.map(\.source) == ["two", "three"])
        // Back-filling an evicted id is a safe no-op.
        buffer.setTranslation("一", for: a)
        #expect(buffer.recent.allSatisfy { $0.translation == nil })
    }

    @Test func ignoresEmptySourceAndEmptyTranslation() {
        let buffer = BilingualContextBuffer(capacity: 3)
        let id = UUID()
        buffer.append(id: UUID(), source: "   ")
        #expect(buffer.recent.isEmpty)
        buffer.append(id: id, source: "Hi.")
        buffer.setTranslation("  ", for: id)
        #expect(buffer.recent.first?.translation == nil)
    }

    @Test func resetClearsEverything() {
        let buffer = BilingualContextBuffer(capacity: 3)
        buffer.append(id: UUID(), source: "line")
        buffer.reset()
        #expect(buffer.recent.isEmpty)
    }
}
