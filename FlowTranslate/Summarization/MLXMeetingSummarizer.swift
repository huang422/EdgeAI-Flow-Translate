import Foundation
import FlowTranslateCore

/// On-demand content summarizer backed by the shared MLX 4-bit Qwen model
/// (`QwenModelHost`, `mlx-community/Qwen3-4B-Instruct-2507-4bit`) on the Apple
/// Silicon GPU.
///
/// The transcript is **content-agnostic**: it may be a meeting, a lecture, a
/// video, a podcast, an interview or a casual conversation — the prompts adapt to
/// whatever the audio actually is instead of assuming "meeting minutes".
///
/// Design for a small (4-bit, 4B) model:
/// * **Map-reduce** — long transcripts are condensed chunk-by-chunk first.
/// * **One language per call** — English and Traditional Chinese are produced by
///   two separate generations. A single, focused task gives a small model far
///   better language adherence and structure than asking for both at once.
/// * **Tolerant parsing** — the model is asked for JSON, but the output is parsed
///   with a balanced-brace extractor and, if that still fails, the prose is shown
///   as the overview. A stray character (the old `Unexpected character '<'`
///   crash) can no longer fail the whole summary.
///
/// It shares the one `QwenModelHost` with live translation, so the model is loaded
/// at most once; the owner (`CaptureViewModel`) frees it after the summary.
public final class MLXMeetingSummarizer: MeetingSummarizing {
    private let host: QwenModelHost
    private let chunkCharBudget: Int
    private var modelId: String { host.modelId }

    init(host: QwenModelHost, chunkCharBudget: Int = 5000) {
        self.host = host
        self.chunkCharBudget = chunkCharBudget
    }

    private enum Lang {
        case english, chinese
    }

    public func summarizeBilingual(
        session: Session,
        segments: [TranscriptSegment],
        progress: ((Double) -> Void)?
    ) async throws -> (english: Summary, chinese: Summary) {
        let lines = transcriptLines(segments)
        guard !lines.isEmpty else {
            let en = Summary(sessionId: session.id, overview: "No content to summarize.", modelName: modelId)
            let zh = Summary(sessionId: session.id, overview: "沒有可摘要的內容。", modelName: modelId)
            return (en, zh)
        }

        progress?(0.05)
        // Load (or reuse) the shared Qwen model. Its memory is freed by the owner
        // (CaptureViewModel) after the summary — translation may already have it.
        try await host.ensureLoaded { p in progress?(0.05 + 0.1 * p) }

        // ---- Map: condense the transcript into compact English notes ----
        let condensed = try await condense(lines) { p in progress?(0.15 + 0.45 * p) }
        progress?(0.6)

        // ---- Reduce: one structured summary per language ----
        let english = try await summarizeOne(condensed, language: .english, sessionId: session.id)
        progress?(0.8)
        let chinese = try await summarizeOne(condensed, language: .chinese, sessionId: session.id)
        progress?(1.0)
        return (english, chinese)
    }

    // MARK: - Map (condense)

    /// Collapse the transcript to compact English working notes. Short transcripts
    /// pass through untouched; long ones are summarized chunk-by-chunk so the final
    /// reduce step always fits the model's context.
    private func condense(_ lines: [String], progress: (Double) -> Void) async throws -> String {
        let chunks = chunked(lines, budget: chunkCharBudget)
        guard chunks.count > 1 else { progress(1); return chunks[0] }

        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            // On a per-chunk failure keep the raw chunk rather than aborting the
            // whole summary.
            let note = await host.generate(
                system: Self.mapSystemPrompt, user: chunk, maxTokens: 700, temperature: 0.3
            )
            notes.append(note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? chunk)
            progress(Double(i + 1) / Double(chunks.count))
        }
        return notes.joined(separator: "\n")
    }

    // MARK: - Reduce (one language)

    /// Generate a structured summary for a single language, parse it tolerantly and
    /// fall back to showing the prose if the model didn't return clean JSON.
    private func summarizeOne(_ condensed: String, language: Lang, sessionId: UUID) async throws -> Summary {
        let user = condensed + "\n\n———\n" + Self.reduceReminder(language)
        guard let raw = await host.generate(
            system: Self.reduceSystemPrompt(language), user: user,
            maxTokens: 1600, temperature: 0.4
        )?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            // The model produced nothing (load/OOM) — let the caller use the
            // extractive fallback for both languages.
            throw SummarizerError.invalidOutput
        }

        if let dto = decodeSummary(from: raw), let summary = summary(from: dto, sessionId: sessionId),
           !summary.overview.isEmpty || !summary.keyPoints.isEmpty {
            return summary
        }
        // Graceful degradation: the model wrote prose (or imperfect JSON). Show it
        // as the overview instead of failing the whole summary.
        return Summary(sessionId: sessionId, overview: salvageProse(raw), modelName: modelId)
    }

    // MARK: - Transcript shaping

    private func transcriptLines(_ segments: [TranscriptSegment]) -> [String] {
        segments.compactMap { seg in
            let src = seg.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !src.isEmpty else { return nil }
            let speaker = seg.speakerLabel.map { "\($0): " } ?? ""
            if let zh = seg.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines), !zh.isEmpty, zh != src {
                return "\(speaker)\(src) / \(zh)"
            }
            return "\(speaker)\(src)"
        }
    }

    private func chunked(_ lines: [String], budget: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if current.count + line.count + 1 > budget, !current.isEmpty {
                chunks.append(current); current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [""] : chunks
    }

    // MARK: - JSON parsing (tolerant)

    private struct SummaryDTO: Decodable {
        var title: String?
        var overview: String?
        var keyPoints: [String]?
        var decisions: [String]?
        var actionItems: [ActionItemDTO]?
        var qa: [QADTO]?
        var glossary: [GlossaryDTO]?
    }
    private struct ActionItemDTO: Decodable { var text: String; var owner: String?; var due: String? }
    private struct QADTO: Decodable { var question: String; var answer: String }
    private struct GlossaryDTO: Decodable { var term: String; var definition: String }

    /// Decode the best JSON object in the text: scan every top-level `{ … }`
    /// (ignoring code fences and any prose/braces around them) and return the first
    /// one that yields a summary with actual content. This is robust to the model
    /// adding commentary, code fences, or trailing junk after the object.
    private func decodeSummary(from raw: String) -> SummaryDTO? {
        for json in Self.jsonObjects(in: raw) {
            guard let data = json.data(using: .utf8),
                  let dto = try? JSONDecoder().decode(SummaryDTO.self, from: data) else { continue }
            let hasContent = !(dto.overview?.isEmpty ?? true)
                || !(dto.keyPoints?.isEmpty ?? true)
                || !(dto.title?.isEmpty ?? true)
            if hasContent { return dto }
        }
        return nil
    }

    /// Every top-level `{ … }` slice in the text, in order. Braces inside string
    /// literals are skipped so trailing content (`}…<…`) can't corrupt a slice the
    /// way a naive first-`{`/last-`}` search did (the old `Unexpected '<'` crash).
    static func jsonObjects(in raw: String) -> [String] {
        var objects: [String] = []
        var depth = 0, inString = false, escaped = false
        var start: String.Index?
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if c == "}", depth > 0 {
                depth -= 1
                if depth == 0, let s = start { objects.append(String(raw[s...i])); start = nil }
            }
            i = raw.index(after: i)
        }
        return objects
    }

    /// Turn non-JSON (or unparseable) model output into a readable overview: drop
    /// code fences and trim. Never empty.
    private func salvageProse(_ raw: String) -> String {
        var s = raw
        for fence in ["```json", "```JSON", "```"] {
            s = s.replacingOccurrences(of: fence, with: "")
        }
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? raw : cleaned
    }

    private func summary(from dto: SummaryDTO, sessionId: UUID) -> Summary? {
        var overview = dto.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let title = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            overview = overview.isEmpty ? title : "【\(title)】\n\(overview)"
        }
        return Summary(
            sessionId: sessionId,
            overview: overview,
            keyPoints: (dto.keyPoints ?? []).cleaned,
            decisions: (dto.decisions ?? []).cleaned,
            actionItems: (dto.actionItems ?? []).compactMap {
                let t = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : ActionItem(text: t, owner: $0.owner?.nilIfBlank, due: $0.due?.nilIfBlank)
            },
            qa: (dto.qa ?? []).compactMap {
                let q = $0.question.trimmingCharacters(in: .whitespacesAndNewlines)
                let a = $0.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                return (q.isEmpty && a.isEmpty) ? nil : QAPair(question: q, answer: a)
            },
            glossary: (dto.glossary ?? []).compactMap {
                let term = $0.term.trimmingCharacters(in: .whitespacesAndNewlines)
                return term.isEmpty ? nil : GlossaryTerm(term: term, definition: $0.definition.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            modelName: modelId
        )
    }

    public enum SummarizerError: Error { case invalidOutput }

    // MARK: - Prompts

    private static let mapSystemPrompt = """
    You are an expert note-taker. Below is part of a transcript of spoken audio — it \
    may be a meeting, lecture, video, podcast, interview or casual conversation. Write \
    concise, factual bullet notes in English that capture the topics, key information, \
    names, numbers, decisions and any action items. Keep every concrete detail and drop \
    filler. Output only the notes.
    """

    private static func reduceSystemPrompt(_ language: Lang) -> String {
        let languageRule: String
        switch language {
        case .english:
            languageRule = "Write every value in English."
        case .chinese:
            languageRule = "Write every value in Traditional Chinese only (繁體中文／台灣正體字). "
                + "You MUST use Traditional Chinese characters and must NEVER output any Simplified Chinese character."
        }
        return """
        You are an expert at summarizing transcribed audio. The content may be a meeting, \
        lecture, video, podcast, interview or conversation — adapt to whatever it actually \
        is rather than assuming a meeting.

        Return ONLY a single JSON object — no markdown, no code fences, no commentary before \
        or after — in exactly this shape:
        {
          "title": "a short descriptive title for the content",
          "overview": "a clear 2-5 sentence summary of what the content is about and its main takeaways",
          "keyPoints": ["the most important points, topics or facts, one per item"],
          "decisions": ["concrete decisions or conclusions reached, if any"],
          "actionItems": [{"text": "a task or next step", "owner": "who or null", "due": "when or null"}],
          "qa": [{"question": "a notable question raised", "answer": "the answer given"}],
          "glossary": [{"term": "a key term, name or acronym", "definition": "a brief explanation"}]
        }
        Use an empty array [] for any section that does not apply to this content. Base \
        everything strictly on the transcript and do not invent facts. \(languageRule)
        """
    }

    private static func reduceReminder(_ language: Lang) -> String {
        switch language {
        case .english:
            return "Now output ONLY the JSON object described above, with all values in English."
        case .chinese:
            return "現在只輸出上述 JSON 物件，所有文字值必須是繁體中文（台灣正體字），"
                + "絕對不可出現任何簡體字，也不要加上任何說明或程式碼框。"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.isEmpty || t.lowercased() == "null") ? nil : t
    }
}

private extension Array where Element == String {
    /// Trim, drop blanks and de-duplicate while preserving order.
    var cleaned: [String] {
        var seen = Set<String>()
        return compactMap { s -> String? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { return nil }
            return t
        }
    }
}
