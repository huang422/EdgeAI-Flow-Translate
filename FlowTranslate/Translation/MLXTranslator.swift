import Foundation
import MLXLLM
import MLXLMCommon

/// On-device sentence translator backed by the MLX **Qwen3-1.7B** (4-bit) model.
///
/// Used when the first caption is "auto" (Apple can't auto-detect a source) or
/// when Apple's Translation framework doesn't support the chosen language pair.
/// The model is kept loaded for the meeting and released afterwards.
///
/// Files are fetched via `MLXModelDownloader` (plain `URLSession`) and loaded with
/// a directory-based `ModelConfiguration`, avoiding the Hub client. Translation
/// runs in Qwen3's **non-thinking** mode (`/no_think`) for low latency.
final class MLXTranslator {
    private let downloader: MLXModelDownloader
    private var container: ModelContainer?

    init(modelId: String = "mlx-community/Qwen3-1.7B-4bit") {
        downloader = MLXModelDownloader(repoId: modelId)
    }

    var isLoaded: Bool { container != nil }

    /// Download the model files to disk **without loading them into memory**.
    /// Safe to call repeatedly (skips files already present).
    func prefetch(progress: ((Double) -> Void)? = nil) async throws {
        if downloader.isComplete { progress?(1); return }
        try await downloader.download(progress: progress)
    }

    /// Load the model into memory (idempotent). Downloads first if needed.
    func ensureLoaded(progress: ((Double) -> Void)? = nil) async throws {
        if container != nil { return }
        if !downloader.isComplete { try await downloader.download(progress: progress) }
        let configuration = ModelConfiguration(directory: downloader.directory)
        container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
    }

    /// Free the model from memory.
    func unload() { container = nil }

    /// Translate one sentence into `target` (the currently selected second-caption
    /// language, e.g. "English" or "繁體中文（台灣正體字…）"). The model itself is
    /// instructed to emit exactly that language — no post-processing. Returns nil
    /// on failure.
    func translate(_ text: String, target: String) async -> String? {
        guard let container else { return nil }
        // Enforce the selected target language through the model itself (strict
        // prompt + low temperature) — no post-hoc character conversion.
        let system = "You are a professional real-time subtitle translator. "
            + "Translate the user's text into \(target). "
            + "Output ONLY the translation in \(target) — no quotes, no notes, no pinyin, not the original text."
        let output: String? = try? await container.perform { context in
            let messages: [[String: Any]] = [
                ["role": "system", "content": system],
                // `/no_think` keeps Qwen3 in fast (non-reasoning) mode for low latency.
                ["role": "user", "content": text + " /no_think"],
            ]
            let input = try await context.processor.prepare(input: UserInput(messages: messages))
            let params = GenerateParameters(temperature: 0.1)
            let result = try MLXLMCommon.generate(input: input, parameters: params, context: context) { tokens in
                tokens.count >= 256 ? .stop : .more
            }
            return result.output
        }
        guard let output else { return nil }
        return MLXThinking.strip(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Removes Qwen3 `<think>…</think>` reasoning blocks from model output.
enum MLXThinking {
    static func strip(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        return String(text[close.upperBound...])
    }
}
