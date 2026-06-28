import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct SummarizerExtraTests {
    private func session() -> Session { Session(endedAt: Date(), title: "T") }

    @Test func extractsQAAndGlossary() async throws {
        let s = session()
        let segs = [
            TranscriptSegment(sessionId: s.id, index: 0, startTime: 0, endTime: 1,
                              source: .system, sourceText: "What is Kubernetes?",
                              translatedText: "什麼是 Kubernetes？"),
            TranscriptSegment(sessionId: s.id, index: 1, startTime: 1, endTime: 2,
                              source: .system, sourceText: "Kubernetes is an orchestrator",
                              translatedText: "Kubernetes 是一個編排器"),
            TranscriptSegment(sessionId: s.id, index: 2, startTime: 2, endTime: 3,
                              source: .system, sourceText: "We use Kubernetes daily",
                              translatedText: "我們每天使用 Kubernetes"),
        ]
        let summary = try await ExtractiveSummarizer().summarize(session: s, segments: segs, progress: nil)
        #expect(summary.qa.contains { $0.question.contains("Kubernetes") })
        // "Kubernetes" appears 3x in the English source -> glossary term.
        #expect(summary.glossary.contains { $0.term == "Kubernetes" })
    }
}

@Suite struct CleanerExtraTests {
    @Test func removesAdjacentFillers() {
        let cleaner = BasicTextCleaner()
        let out = cleaner.cleanup("well um um so this works")
        #expect(!out.lowercased().contains(" um "))
        #expect(out.contains("this works"))
    }
}
