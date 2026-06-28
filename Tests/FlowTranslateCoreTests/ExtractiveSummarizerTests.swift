import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct ExtractiveSummarizerTests {
    private func session() -> Session { Session(endedAt: Date(), title: "T") }

    private func segs(_ s: Session) -> [TranscriptSegment] {
        [
            TranscriptSegment(sessionId: s.id, index: 0, startTime: 0, endTime: 1,
                              source: .system, sourceText: "Welcome", translatedText: "歡迎大家參加會議"),
            TranscriptSegment(sessionId: s.id, index: 1, startTime: 1, endTime: 2,
                              source: .system, sourceText: "We decide to ship", translatedText: "我們決定下週發布版本"),
            TranscriptSegment(sessionId: s.id, index: 2, startTime: 2, endTime: 3,
                              source: .microphone, sourceText: "Tom will follow up", translatedText: "Tom 負責後續追蹤")
        ]
    }

    @Test func producesStructuredSummary() async throws {
        let s = session()
        let summary = try await ExtractiveSummarizer().summarize(session: s, segments: segs(s), progress: nil)
        #expect(summary.sessionId == s.id)
        #expect(!summary.overview.isEmpty)
        #expect(!summary.keyPoints.isEmpty)
        #expect(summary.decisions.contains { $0.contains("決定") })
        #expect(summary.actionItems.contains { $0.text.contains("負責") })
        #expect(summary.modelName == "extractive-fallback")
    }

    @Test func handlesEmptyTranscript() async throws {
        let s = session()
        let summary = try await ExtractiveSummarizer().summarize(session: s, segments: [], progress: nil)
        #expect(!summary.overview.isEmpty)
        #expect(summary.keyPoints.isEmpty)
    }
}
