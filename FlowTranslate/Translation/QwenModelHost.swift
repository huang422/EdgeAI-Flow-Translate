import Foundation
import FlowTranslateCore
import MLXLLM
import MLXLMCommon

/// Single shared owner of the on-device Qwen model container. Live translation and
/// the post-meeting summary both run through this one instance, so the ~2.3 GB
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
        temperature: Float, topP: Float = 0.9, repetitionPenalty: Float? = 1.1,
        repetitionContextSize: Int = 20,
        shouldStop: @escaping @Sendable () -> Bool = { false }
    ) async -> String? {
        await run(
            system: system, user: user, maxTokens: maxTokens,
            temperature: temperature, topP: topP, repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            shouldStop: shouldStop, onProgress: nil
        )
    }

    /// Same as `generate`, but reports how many tokens have been produced so far.
    ///
    /// Exists because a prompt compile is a multi-second generation on an M1 Pro,
    /// and an indeterminate spinner for that long is indistinguishable from a
    /// hang. `onProgress` is invoked from the model's own execution context, not
    /// the MainActor — hop before touching UI state.
    func generateStreaming(
        system: String, user: String, maxTokens: Int,
        temperature: Float, topP: Float = 0.9, repetitionPenalty: Float? = 1.1,
        repetitionContextSize: Int = 20,
        shouldStop: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Int) -> Void
    ) async -> String? {
        await run(
            system: system, user: user, maxTokens: maxTokens,
            temperature: temperature, topP: topP, repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            shouldStop: shouldStop, onProgress: onProgress
        )
    }

    /// How often the token counter is reported. Fast enough to read as live,
    /// ~1% of the cost of reporting every token.
    static let progressStride = 8

    /// The single generation path. `generate` forwards to it unchanged, so the
    /// live-translation, transcript-correction and summary callers keep byte-for-byte
    /// identical behaviour; only the optional progress callback is new.
    /// Both new parameters are defaulted to the previous behaviour, so every
    /// existing caller — live translation, transcript correction, the summarizer,
    /// the prompt compiler — generates byte-for-byte as before.
    ///
    /// `repetitionContextSize` is a knob because 20 tokens is the right window
    /// for a one-sentence answer and the wrong one for a passage: a degenerate
    /// loop with a period longer than the window is invisible to the penalty, and
    /// a whole-transcript repair generates ten times as many tokens as anything
    /// else here.
    ///
    /// `shouldStop` exists because a long generation has no other checkpoint.
    /// `MLXLMCommon.generate`'s closure was consulted only for the token cap, so
    /// a cancelled task kept the GPU until the cap was reached — and
    /// `cancelAndDrain()` is called *before a meeting starts*, so a stale
    /// half-minute repair would have delayed a meeting by half a minute.
    private func run(
        system: String, user: String, maxTokens: Int,
        temperature: Float, topP: Float, repetitionPenalty: Float?,
        repetitionContextSize: Int = 20,
        shouldStop: @escaping @Sendable () -> Bool = { false },
        onProgress: (@Sendable (Int) -> Void)?
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
                repetitionPenalty: repetitionPenalty,
                repetitionContextSize: repetitionContextSize
            )
            // The TokenIterator stops at `maxTokens` and at any EOS token; the closure
            // is a final hard cap in case `maxTokens` is left nil upstream.
            // Report every Nth token, not every token. This closure runs once
            // per generated token, and each consumer hops to the MainActor,
            // writes a `@Published` value and re-evaluates a view body — one of
            // them also resizes an NSPanel. At a 900-token cap that was 900
            // task allocations and 900 view invalidations per compile, for a
            // counter nobody can read changing that fast.
            let result = try MLXLMCommon.generate(input: input, parameters: params, context: context) { tokens in
                if tokens.count % Self.progressStride == 0 {
                    onProgress?(tokens.count)
                    if shouldStop() { return .stop }
                }
                return tokens.count >= maxTokens ? .stop : .more
            }
            return result.output
        }
        guard let output else { return nil }
        return MLXThinking.strip(output)
    }

    // MARK: - Token counting

    /// Real BPE token count for `text`, or `nil` when the model is not loaded.
    ///
    /// This is the model's own tokenizer, read from the `tokenizer.json` that
    /// ships beside the weights — so for anything this app itself generates, the
    /// number is exact rather than estimated. It costs no download, no new
    /// dependency and no network: `swift-transformers` is already in the graph
    /// underneath `MLXLMCommon`, and the tokenizer is already resident.
    ///
    /// Deliberately does **not** load the model. Counting characters in a text
    /// field must never pull 2.3 GB into memory, so an unloaded host answers
    /// `nil` and the caller falls back to the heuristic.
    func countTokens(_ text: String) async -> Int? {
        guard !text.isEmpty, let container else { return nil }
        // `perform` is not throwing here: the closure only reads the tokenizer.
        return await container.perform { context in
            // `addSpecialTokens: false`. The default is `true`, which appends the
            // tokenizer's BOS/EOS markers — real tokens for a standalone
            // generation, but not part of what this *fragment* costs once it is
            // wrapped in a chat template that supplies its own. Counting them
            // inflates every number, and proportionally most on the short strings
            // where the count matters least in absolute terms and most as a ratio.
            context.tokenizer.encode(text: text, addSpecialTokens: false).count
        }
    }
}

/// Bridges the app's loaded Qwen tokenizer to `FlowTranslateCore`'s counting
/// protocol.
///
/// Synchronous by contract because it is called from view-model property reads,
/// so it serves a cache that the async path refreshes. A miss returns `nil` and
/// the meter falls back to the character heuristic — the readout is labelled
/// with which one it used, so a fallback is visible rather than silent.
final class QwenTokenCounter: TokenCounting, @unchecked Sendable {
    private let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        // Keyed by the whole prompt text, and the composer stores a new pair on
        // every render — which is every keystroke. `NSCache` evicts only under
        // memory pressure, so without a limit a long editing session accumulates
        // a copy of every intermediate draft to hold an integer about it.
        cache.countLimit = 200
        return cache
    }()

    func count(_ text: String) -> Int? {
        cache.object(forKey: text as NSString)?.intValue
    }

    func store(_ count: Int, for text: String) {
        cache.setObject(NSNumber(value: count), forKey: text as NSString)
    }
}

/// Removes Qwen3 `<think>…</think>` reasoning blocks from model output.
enum MLXThinking {
    static func strip(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        return String(text[close.upperBound...])
    }
}
