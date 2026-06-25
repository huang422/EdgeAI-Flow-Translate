import Foundation
import MLXLLM
import MLXLMCommon

/// Single shared owner of the on-device Qwen model container. Live translation and
/// the post-meeting summary both run through this one instance, so the ~2.5 GB
/// (Qwen3-4B-Instruct-2507 4-bit) model is loaded into memory **at most once** and freed (together
/// with the MLX cache) exactly once — instead of each consumer keeping its own copy.
/// This is the core of the memory budget on a 16 GB machine.
///
/// Files are fetched via `MLXModelDownloader` (plain `URLSession`) and loaded with
/// a directory-based `ModelConfiguration`, avoiding the Hugging Face Hub client
/// (see [[mlx-hub-download-location]]). Generation strips Qwen3 `<think>` blocks.
///
/// Access is effectively serialized: all callers drive it from the MainActor and
/// the translation / summary phases never overlap, so one model runs one generation
/// at a time (a `ModelContainer` serializes `perform` internally too).
final class QwenModelHost: @unchecked Sendable {
    private let downloader: MLXModelDownloader
    private var container: ModelContainer?
    let modelId: String

    init(modelId: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit") {
        self.modelId = modelId
        self.downloader = MLXModelDownloader(repoId: modelId)
    }

    /// Whether the model is resident in memory.
    var isLoaded: Bool { container != nil }
    /// Whether the model files are already on disk (no download needed).
    var isComplete: Bool { downloader.isComplete }

    /// Download the model files to disk WITHOUT loading them into memory. Safe to
    /// call repeatedly (skips files already present).
    func prefetch(progress: ((Double) -> Void)? = nil) async throws {
        if downloader.isComplete { progress?(1); return }
        try await downloader.download(progress: progress)
    }

    /// Load the model into memory (idempotent). Downloads first if needed.
    func ensureLoaded(progress: ((Double) -> Void)? = nil) async throws {
        if container != nil { return }
        if !downloader.isComplete { try await downloader.download(progress: progress) }
        // `extraEOSTokens` is belt-and-suspenders: the Qwen3 chat turn terminator
        // `<|im_end|>` is already the tokenizer's `eos_token`, but registering it
        // explicitly guarantees generation stops at the end of the assistant turn
        // even if a future model conversion sets a different `eos_token`.
        let configuration = ModelConfiguration(
            directory: downloader.directory,
            extraEOSTokens: ["<|im_end|>", "<|endoftext|>"]
        )
        container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
    }

    /// Free the model from memory and return its buffers to the OS.
    func unload() {
        container = nil
        MLXMemory.reclaim()
    }

    /// Run one chat-style generation on the shared container. Loads the model on
    /// first use. Returns the thinking-stripped output, or nil on failure.
    ///
    /// `topP` + `repetitionPenalty` are deliberate: the 4-bit quantized model can
    /// fall into token-repetition loops at very low temperature, so a mild penalty
    /// and nucleus sampling keep the output stable without hurting determinism.
    func generate(
        system: String, user: String, maxTokens: Int,
        temperature: Float, topP: Float = 0.9, repetitionPenalty: Float? = 1.1
    ) async -> String? {
        guard (try? await ensureLoaded()) != nil, let container else { return nil }
        let output: String? = try? await container.perform { context in
            let messages: [[String: Any]] = [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ]
            let input = try await context.processor.prepare(input: UserInput(messages: messages))
            let params = GenerateParameters(
                maxTokens: maxTokens, temperature: temperature, topP: topP,
                repetitionPenalty: repetitionPenalty, repetitionContextSize: 20
            )
            // The TokenIterator stops at `maxTokens` and at any EOS token; the closure
            // is a final hard cap in case `maxTokens` is left nil upstream.
            let result = try MLXLMCommon.generate(input: input, parameters: params, context: context) { tokens in
                tokens.count >= maxTokens ? .stop : .more
            }
            return result.output
        }
        guard let output else { return nil }
        return MLXThinking.strip(output)
    }
}

/// Removes Qwen3 `<think>…</think>` reasoning blocks from model output.
enum MLXThinking {
    static func strip(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        return String(text[close.upperBound...])
    }
}
