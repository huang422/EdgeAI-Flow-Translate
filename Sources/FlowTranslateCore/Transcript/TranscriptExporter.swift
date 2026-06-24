import Foundation

/// Transcript exporter (contracts/transcript-store.md). Supports Markdown/TXT/SRT/VTT/JSON.
/// Can render separate English and Traditional Chinese meeting summaries.
public struct TranscriptExporter: TranscriptExporting {
    public init() {}

    /// Protocol entry point (single summary).
    public func export(
        session: Session,
        segments: [TranscriptSegment],
        summary: Summary?,
        format: ExportFormat
    ) throws -> Data {
        try render(session: session, segments: segments, chinese: summary, english: nil, format: format)
    }

    /// Bilingual export: separate English + Traditional Chinese summaries.
    public func exportBilingual(
        session: Session,
        segments: [TranscriptSegment],
        chinese: Summary?,
        english: Summary?,
        format: ExportFormat
    ) throws -> Data {
        try render(session: session, segments: segments, chinese: chinese, english: english, format: format)
    }

    public enum ExportError: Error { case encodingFailed }

    // MARK: - Dispatch

    private func render(
        session: Session, segments: [TranscriptSegment],
        chinese: Summary?, english: Summary?, format: ExportFormat
    ) throws -> Data {
        let string: String
        switch format {
        case .markdown:
            string = renderMarkdown(session: session, segments: segments, chinese: chinese, english: english)
        case .plainText:
            string = renderPlainText(session: session, segments: segments, chinese: chinese, english: english)
        case .srt:
            string = renderSRT(segments: segments)
        case .vtt:
            string = renderVTT(segments: segments)
        case .json:
            return try renderJSON(session: session, segments: segments, chinese: chinese, english: english)
        }
        guard let data = string.data(using: .utf8) else { throw ExportError.encodingFailed }
        return data
    }

    // MARK: - Renderers

    private func speakerPrefix(_ seg: TranscriptSegment) -> String {
        if let s = seg.speakerLabel { return "[\(s)] " }
        return ""
    }

    private func renderMarkdown(session: Session, segments: [TranscriptSegment], chinese: Summary?, english: Summary?) -> String {
        var out = "# \(session.title ?? "Meeting Transcript")\n\n"
        out += "- Started: \(iso(session.startedAt))\n"
        if let e = session.endedAt { out += "- Ended: \(iso(e))\n" }
        out += "- Languages: \(session.firstLanguage) → \(session.secondLanguage)\n\n"
        out += "## Transcript\n\n"
        for seg in segments {
            out += "**\(timestamp(seg.startTime)) \(speakerPrefix(seg))(\(seg.source.rawValue))**\n\n"
            out += "- \(seg.sourceText)\n"
            if let t = seg.translatedText { out += "- \(t)\n" }
            out += "\n"
        }
        if let english { out += renderSummaryMarkdown(english, title: "Summary (English)") }
        if let chinese { out += renderSummaryMarkdown(chinese, title: "Summary (繁體中文)") }
        return out
    }

    private func renderSummaryMarkdown(_ s: Summary, title: String) -> String {
        var out = "## \(title)\n\n\(s.overview)\n\n"
        if !s.keyPoints.isEmpty {
            out += "### 重點 Key Points\n\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !s.decisions.isEmpty {
            out += "### 決議 Decisions\n\n" + s.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !s.actionItems.isEmpty {
            out += "### 待辦 Action Items\n\n"
            for a in s.actionItems {
                var line = "- \(a.text)"
                if let o = a.owner { line += " (負責: \(o))" }
                if let d = a.due { line += " (期限: \(d))" }
                out += line + "\n"
            }
            out += "\n"
        }
        if !s.qa.isEmpty {
            out += "### Q&A\n\n"
            for q in s.qa { out += "- **Q:** \(q.question)\n  - **A:** \(q.answer)\n" }
            out += "\n"
        }
        if !s.glossary.isEmpty {
            out += "### 名詞表 Glossary\n\n"
            for g in s.glossary { out += "- **\(g.term)**: \(g.definition)\n" }
            out += "\n"
        }
        return out
    }

    private func renderPlainText(session: Session, segments: [TranscriptSegment], chinese: Summary?, english: Summary?) -> String {
        var out = "\(session.title ?? "Meeting Transcript")\n\n"
        for seg in segments {
            out += "\(timestamp(seg.startTime)) \(speakerPrefix(seg))(\(seg.source.rawValue))\n"
            out += "  \(seg.source == .microphone ? "MIC" : "SYS") | \(seg.sourceText)\n"
            if let t = seg.translatedText { out += "  ZH: \(t)\n" }
            out += "\n"
        }
        if let english { out += "=== Summary (English) ===\n\(english.overview)\n\n" }
        if let chinese { out += "=== 摘要 (繁體中文) ===\n\(chinese.overview)\n" }
        return out
    }

    private func renderSRT(segments: [TranscriptSegment]) -> String {
        var out = ""
        for (i, seg) in segments.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTime(seg.startTime)) --> \(srtTime(seg.endTime))\n"
            out += "\(seg.sourceText)\n"
            if let t = seg.translatedText { out += "\(t)\n" }
            out += "\n"
        }
        return out
    }

    private func renderVTT(segments: [TranscriptSegment]) -> String {
        var out = "WEBVTT\n\n"
        for (i, seg) in segments.enumerated() {
            out += "\(i + 1)\n"
            out += "\(vttTime(seg.startTime)) --> \(vttTime(seg.endTime))\n"
            out += "\(seg.sourceText)\n"
            if let t = seg.translatedText { out += "\(t)\n" }
            out += "\n"
        }
        return out
    }

    private func renderJSON(session: Session, segments: [TranscriptSegment], chinese: Summary?, english: Summary?) throws -> Data {
        struct Payload: Codable {
            let session: Session
            let segments: [TranscriptSegment]
            let summaryEnglish: Summary?
            let summaryChinese: Summary?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Payload(session: session, segments: segments,
                                          summaryEnglish: english, summaryChinese: chinese))
    }

    // MARK: - Time formatting

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func timestamp(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// SRT uses a comma before milliseconds: HH:MM:SS,mmm
    func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let milli = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, milli)
    }

    /// VTT uses a dot before milliseconds: HH:MM:SS.mmm
    func vttTime(_ t: TimeInterval) -> String {
        srtTime(t).replacingOccurrences(of: ",", with: ".")
    }
}
