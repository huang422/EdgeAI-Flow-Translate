import Foundation

/// Pure-Swift extractive summarizer (non-LLM fallback). Provides a structured
/// summary when no MLX model is available. Produces separate English and
/// Traditional Chinese summaries (English from the source text, Chinese from the
/// translation).
public final class ExtractiveSummarizer: MeetingSummarizing {
    public init() {}

    public func summarizeBilingual(
        session: Session,
        segments: [TranscriptSegment],
        progress: ((Double) -> Void)?
    ) async throws -> (english: Summary, chinese: Summary) {
        progress?(0.1)

        // English from the recognized source text.
        let enLines = segments
            .map { $0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Chinese from the translation, falling back to source when missing.
        let zhLines = segments
            .map { ($0.translatedText?.isEmpty == false ? $0.translatedText! : $0.sourceText)
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        progress?(0.6)
        let english = build(session: session, lines: enLines, language: .english)
        let chinese = build(session: session, lines: zhLines, language: .chinese)
        progress?(1.0)
        return (english, chinese)
    }

    // MARK: - Build

    private enum Lang { case english, chinese }

    private func build(session: Session, lines: [String], language: Lang) -> Summary {
        let overview: String
        if lines.isEmpty {
            overview = language == .english
                ? "No content to summarize for this meeting."
                : "本次會議沒有可摘要的內容。"
        } else {
            overview = language == .english
                ? "This meeting had \(lines.count) spoken segments, covering the points below."
                : "本次會議共 \(lines.count) 句發言，涵蓋以下重點。"
        }

        // Key points: the longer (more informative) sentences.
        let keyPoints = Array(lines.sorted { $0.count > $1.count }.prefix(6))

        let decisionKeywords = ["決定", "決議", "通過", "agree", "decide", "conclusion"]
        let actionKeywords = ["待辦", "負責", "action", "todo", "will ", "需要", "下一步", "follow up"]

        let decisions = dedupe(lines.filter { line in
            decisionKeywords.contains { line.lowercased().contains($0.lowercased()) }
        })
        let actionItems = dedupe(lines.filter { line in
            actionKeywords.contains { line.lowercased().contains($0.lowercased()) }
        }).map { ActionItem(text: $0) }

        return Summary(
            sessionId: session.id,
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            qa: extractQA(lines),
            glossary: extractGlossary(lines),
            modelName: "extractive-fallback"
        )
    }

    // MARK: - Helpers

    private func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private func extractQA(_ lines: [String]) -> [QAPair] {
        var pairs: [QAPair] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if (line.hasSuffix("?") || line.hasSuffix("？")), i + 1 < lines.count {
                pairs.append(QAPair(question: line, answer: lines[i + 1]))
                i += 2
            } else {
                i += 1
            }
        }
        return Array(pairs.prefix(8))
    }

    private func extractGlossary(_ lines: [String]) -> [GlossaryTerm] {
        var counts: [String: Int] = [:]
        for line in lines {
            for raw in line.split(whereSeparator: { !$0.isLetter }) {
                let token = String(raw)
                guard token.count >= 3, let first = token.first, first.isUppercase else { continue }
                counts[token, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { GlossaryTerm(term: $0.key, definition: "Mentioned \($0.value) times") }
    }
}
