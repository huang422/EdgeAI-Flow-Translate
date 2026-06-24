import Foundation
import FlowTranslateCore
import MLXLLM
import MLXLMCommon

/// On-demand meeting summarizer backed by an MLX 4-bit LLM
/// (`mlx-community/Qwen3-1.7B-4bit`) on the Apple Silicon GPU.
///
/// Produces **separate** English and Traditional Chinese summaries in a single
/// generation. The model is only loaded for this post-meeting step and released
/// afterwards, keeping the real-time (ANE) loop's memory headroom intact.
///
/// The final summary step runs in Qwen3's **thinking** mode for better quality
/// (the fast map step uses `/no_think`). Long transcripts use a **map-reduce**
/// strategy. Any failure (offline, parse error, OOM) is thrown so the caller can
/// fall back to `ExtractiveSummarizer`.
public final class MLXMeetingSummarizer: MeetingSummarizing {
    private let modelId: String
    private let chunkCharBudget: Int
    private let downloader: MLXModelDownloader
    private var container: ModelContainer?

    public init(
        modelId: String = "mlx-community/Qwen3-1.7B-4bit",
        chunkCharBudget: Int = 6000
    ) {
        self.modelId = modelId
        self.chunkCharBudget = chunkCharBudget
        self.downloader = MLXModelDownloader(repoId: modelId)
    }

    public func summarizeBilingual(
        session: Session,
        segments: [TranscriptSegment],
        progress: ((Double) -> Void)?
    ) async throws -> (english: Summary, chinese: Summary) {
        let lines = transcriptLines(segments)
        guard !lines.isEmpty else {
            let en = Summary(sessionId: session.id, overview: "No content to summarize.", modelName: modelId)
            let zh = Summary(sessionId: session.id, overview: "本次會議沒有可摘要的內容。", modelName: modelId)
            return (en, zh)
        }

        progress?(0.05)
        let container = try await loadContainer(progress: progress)
        defer { releaseModel() }

        // ---- Map: condense each chunk (only needed for long transcripts) ----
        let chunks = chunked(lines, budget: chunkCharBudget)
        let condensed: String
        if chunks.count == 1 {
            condensed = chunks[0]
        } else {
            var notes: [String] = []
            for (i, chunk) in chunks.enumerated() {
                let note = try await complete(system: Self.mapSystemPrompt, user: chunk,
                                              container: container, maxTokens: 600, think: false)
                notes.append(note)
                progress?(0.2 + 0.5 * Double(i + 1) / Double(chunks.count))
            }
            condensed = notes.joined(separator: "\n")
        }

        // ---- Reduce: one structured JSON summary with both languages ----
        // Thinking mode on for a higher-quality summary; larger token budget so
        // the reasoning block plus the JSON answer both fit.
        progress?(0.75)
        // Repeat the language rule in the user turn — a small model weights the
        // latest turn most, which curbs the drift to Simplified Chinese.
        let reduceUser = condensed + "\n\n———\n輸出要求（務必遵守）：回傳 JSON 中 "
            + "\"zh\" 區塊的每個文字都必須是繁體中文（台灣正體字），絕對不可出現任何簡體字；"
            + "\"en\" 區塊必須全部是英文。"
        let json = try await complete(system: Self.reduceSystemPrompt, user: reduceUser,
                                      container: container, maxTokens: 4000, think: true)
        progress?(0.95)

        let result = try parseBilingual(json, sessionId: session.id)
        progress?(1.0)
        return result
    }

    // MARK: - Model lifecycle

    private func loadContainer(progress: ((Double) -> Void)?) async throws -> ModelContainer {
        if let container { return container }
        if !downloader.isComplete {
            try await downloader.download { p in progress?(0.05 + 0.15 * p) }
        }
        let configuration = ModelConfiguration(directory: downloader.directory)
        let loaded = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        container = loaded
        return loaded
    }

    private func releaseModel() { container = nil }

    // MARK: - Generation

    /// Run one completion. `think` toggles Qwen3's reasoning mode: on for the
    /// final summary (quality), off (`/no_think`) for the fast map step. Any
    /// `<think>…</think>` block is stripped from the returned text.
    private func complete(system: String, user: String, container: ModelContainer,
                          maxTokens: Int, think: Bool) async throws -> String {
        let userContent = think ? user : user + " /no_think"
        let output = try await container.perform { context in
            let messages: [[String: Any]] = [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ]
            let input = try await context.processor.prepare(input: UserInput(messages: messages))
            let params = GenerateParameters(temperature: 0.2)
            let result = try MLXLMCommon.generate(input: input, parameters: params, context: context) { tokens in
                tokens.count >= maxTokens ? .stop : .more
            }
            return result.output
        }
        return MLXThinking.strip(output)
    }

    // MARK: - Transcript shaping

    private func transcriptLines(_ segments: [TranscriptSegment]) -> [String] {
        segments.compactMap { seg in
            let en = seg.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !en.isEmpty else { return nil }
            let speaker = seg.speakerLabel.map { "\($0): " } ?? ""
            if let zh = seg.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines), !zh.isEmpty {
                return "\(speaker)\(en) / \(zh)"
            }
            return "\(speaker)\(en)"
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

    // MARK: - JSON parsing

    private struct BilingualDTO: Decodable { var en: SummaryDTO?; var zh: SummaryDTO? }
    private struct SummaryDTO: Decodable {
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

    private func parseBilingual(_ raw: String, sessionId: UUID) throws -> (english: Summary, chinese: Summary) {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else {
            throw SummarizerError.invalidOutput
        }
        guard let data = String(raw[start...end]).data(using: .utf8) else { throw SummarizerError.invalidOutput }
        let dto = try JSONDecoder().decode(BilingualDTO.self, from: data)
        guard dto.en != nil || dto.zh != nil else { throw SummarizerError.invalidOutput }
        return (summary(from: dto.en, sessionId: sessionId), summary(from: dto.zh, sessionId: sessionId))
    }

    private func summary(from dto: SummaryDTO?, sessionId: UUID) -> Summary {
        Summary(
            sessionId: sessionId,
            overview: dto?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            keyPoints: dto?.keyPoints ?? [],
            decisions: dto?.decisions ?? [],
            actionItems: (dto?.actionItems ?? []).map { ActionItem(text: $0.text, owner: $0.owner, due: $0.due) },
            qa: (dto?.qa ?? []).map { QAPair(question: $0.question, answer: $0.answer) },
            glossary: (dto?.glossary ?? []).map { GlossaryTerm(term: $0.term, definition: $0.definition) },
            modelName: modelId
        )
    }

    public enum SummarizerError: Error { case invalidOutput }

    // MARK: - Prompts

    private static let mapSystemPrompt = """
    You are a meeting-notes assistant. Below is part of a meeting transcript \
    (English / Traditional Chinese). Condense it into concise English bullet notes, \
    preserving decisions, action items, names and numbers. Output only the notes.
    """

    private static let reduceSystemPrompt = """
    You are a meeting-notes assistant. From the meeting notes below, produce a \
    detailed meeting summary in BOTH languages as SEPARATE versions: "en" written \
    in English, and "zh" written in Traditional Chinese (Taiwan, 正體字). Do not \
    mix the two languages within a field.

    Output ONLY one JSON object, no extra text or markdown code fences, in this shape:
    {
      "en": {
        "overview": "concise English overview",
        "keyPoints": ["..."],
        "decisions": ["..."],
        "actionItems": [{"text": "...", "owner": "name or null", "due": "deadline or null"}],
        "qa": [{"question": "...", "answer": "..."}],
        "glossary": [{"term": "...", "definition": "..."}]
      },
      "zh": {
        "overview": "繁體中文概述",
        "keyPoints": ["..."],
        "decisions": ["..."],
        "actionItems": [{"text": "...", "owner": "負責人或null", "due": "期限或null"}],
        "qa": [{"question": "...", "answer": "..."}],
        "glossary": [{"term": "...", "definition": "..."}]
      }
    }
    Use empty arrays for empty fields. STRICT language rules: every value under \
    "en" must be in English only; every value under "zh" must be in Traditional \
    Chinese only (繁體中文／台灣正體字) — you MUST use Traditional Chinese \
    characters and NEVER output any Simplified Chinese characters.
    """
}
