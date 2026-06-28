import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct TranscriptExporterTests {
    private func sampleSession() -> Session {
        Session(endedAt: Date(), title: "Standup")
    }

    private func sampleSegments(_ session: Session) -> [TranscriptSegment] {
        [
            TranscriptSegment(sessionId: session.id, index: 0, startTime: 0, endTime: 2.5,
                              source: .system, speakerLabel: "Speaker A",
                              sourceText: "Hello everyone", translatedText: "大家好"),
            TranscriptSegment(sessionId: session.id, index: 1, startTime: 2.5, endTime: 5,
                              source: .microphone,
                              sourceText: "Let's begin", translatedText: "我們開始吧")
        ]
    }

    @Test func srtTimeFormat() {
        let exporter = TranscriptExporter()
        #expect(exporter.srtTime(0) == "00:00:00,000")
        #expect(exporter.srtTime(3661.5) == "01:01:01,500")
    }

    @Test func vttTimeFormat() {
        let exporter = TranscriptExporter()
        #expect(exporter.vttTime(3661.5) == "01:01:01.500")
    }

    @Test func exportSRTContainsBilingual() throws {
        let exporter = TranscriptExporter()
        let session = sampleSession()
        let data = try exporter.export(session: session, segments: sampleSegments(session),
                                       summary: nil, format: .srt)
        let str = String(data: data, encoding: .utf8) ?? ""
        #expect(str.contains("Hello everyone"))
        #expect(str.contains("大家好"))
        #expect(str.contains("00:00:00,000 --> 00:00:02,500"))
    }

    @Test func exportVTTHeader() throws {
        let exporter = TranscriptExporter()
        let session = sampleSession()
        let data = try exporter.export(session: session, segments: sampleSegments(session),
                                       summary: nil, format: .vtt)
        let str = String(data: data, encoding: .utf8) ?? ""
        #expect(str.hasPrefix("WEBVTT"))
    }

    @Test func exportMarkdownWithSummaryAndSpeaker() throws {
        let exporter = TranscriptExporter()
        let session = sampleSession()
        let summary = Summary(sessionId: session.id, overview: "簡短會議",
                              keyPoints: ["重點一"], decisions: ["決議一"],
                              actionItems: [ActionItem(text: "待辦一", owner: "Tom")])
        let data = try exporter.export(session: session, segments: sampleSegments(session),
                                       summary: summary, format: .markdown)
        let str = String(data: data, encoding: .utf8) ?? ""
        #expect(str.contains("Speaker A"))
        #expect(str.contains("## Summary"))
        #expect(str.contains("重點一"))
        #expect(str.contains("待辦一"))
        #expect(str.contains("負責: Tom"))
    }

    @Test func exportJSONDecodable() throws {
        let exporter = TranscriptExporter()
        let session = sampleSession()
        let data = try exporter.export(session: session, segments: sampleSegments(session),
                                       summary: nil, format: .json)
        #expect(!data.isEmpty)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(obj is [String: Any])
    }
}
