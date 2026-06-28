import Testing
@testable import FlowTranslateCore

@Suite struct ContextBufferTests {
    @Test func keepsOnlyRecentN() {
        let buf = ContextBuffer(capacity: 2)
        buf.append("one")
        buf.append("two")
        buf.append("three")
        #expect(buf.recent == ["two", "three"])
    }

    @Test func ignoresEmpty() {
        let buf = ContextBuffer(capacity: 3)
        buf.append("   ")
        buf.append("hello")
        #expect(buf.recent == ["hello"])
    }

    @Test func resetClears() {
        let buf = ContextBuffer(capacity: 3)
        buf.append("a")
        buf.reset()
        #expect(buf.recent.isEmpty)
    }
}
