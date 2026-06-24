import AVFoundation
import FluidAudio
import FlowTranslateCore

/// Streaming ASR over FluidAudio's multilingual Nemotron‑3.5 model (CoreML/ANE).
///
/// Key design points:
/// - **One independent pipeline per audio source.** A streaming ASR keeps
///   continuous acoustic state, so feeding system audio and microphone audio into
///   a single model corrupts it (slow / garbled / no output). Each source gets its
///   own `StreamingNemotronMultilingualAsrManager` + VAD + utterance state.
/// - **Model reuse.** The downloaded variant is cached on disk (no re-download)
///   and the in-memory models are kept alive across Start/Stop, so pressing Start
///   again does not reload them.
/// - **Language:** `setLanguage("en-US" / "sv-SE" / "auto" …)`. `en-US` (and other
///   Latin langs) use the lighter, faster "latin" ship; others/`auto` use the
///   "multilingual" ship. `auto` detects per sentence (mixed-language audio).
public final class NemotronStreamingService: ASRStreaming, @unchecked Sendable {
    public var onEvent: ((TranscriptEvent) -> Void)?

    /// First-caption language hint (Nemotron locale, e.g. "en-US", or "auto").
    public var currentLanguage: String = SupportedASRLanguages.default

    /// Reports model load/download progress (0…1) during `loadModels`.
    public var onLoadProgress: ((Double) -> Void)?

    /// Called true when a model starts loading lazily, false when it's ready.
    public var onModelLoading: ((Bool) -> Void)?

    private var variantDir: URL?
    private var loadedKey: String?        // "<language>|<tier>" currently downloaded
    private var pipelines: [AudioSourceType: SourceASR] = [:]
    private var creating: Set<AudioSourceType> = []
    /// Audio captured while a source's pipeline is still being created, replayed
    /// once it's ready so the opening words are never dropped (cold-start fix).
    private var pendingChunks: [AudioSourceType: [AudioChunk]] = [:]
    private let maxPendingChunks = 200   // ~recent audio kept while the model loads
    /// Background-preloaded model, consumed by the first source that needs a
    /// pipeline — so the model is ready by the time the user speaks.
    private var warmTask: Task<StreamingNemotronMultilingualAsrManager?, Never>?
    private var running = false
    private let lock = NSLock()

    public init() {}

    // MARK: - ASRStreaming

    /// Ensure the model for the current language + tier is downloaded and valid
    /// (re-downloads a partial/corrupt cache). Fast when already cached. The model
    /// is loaded into memory lazily on first audio. No-op if already prepared.
    public func loadModels(tier: String) async throws {
        let key = "\(currentLanguage)|\(tier)"
        if loadedKey == key, variantDir != nil { return }   // already prepared, no re-download

        // Settings changed → drop any models loaded for the old settings.
        teardownAll()

        // Only DOWNLOAD here (fast when cached). The model is loaded into memory
        // lazily on the first audio chunk, while incoming audio is buffered — so
        // Start stays fast and the opening words are never dropped.
        variantDir = try await ensureVariant(lang: currentLanguage, chunkMs: Self.chunkMs(for: tier))
        loadedKey = key
        onLoadProgress?(1.0)
    }

    /// Load one model in the background now, so it's ready by the time the user
    /// speaks (overlaps the multi-second load with user prep → less first-caption
    /// delay). The first source that needs a pipeline consumes it.
    private func startBackgroundPreload() {
        lock.withLock {
            guard warmTask == nil, pipelines.isEmpty else { return }
            warmTask = Task { [weak self] in await self?.loadManager() ?? nil }
        }
    }

    /// Load + language-configure one streaming model from the cached variant.
    private func loadManager() async -> StreamingNemotronMultilingualAsrManager? {
        guard let dir = variantDir else { return nil }
        onModelLoading?(true)
        defer { onModelLoading?(false) }
        let m = StreamingNemotronMultilingualAsrManager()
        do {
            try await m.loadModels(from: dir)   // CoreML load + ANE warm-up
        } catch {
            return nil
        }
        await m.setLanguage(currentLanguage)
        return m
    }

    private func ensureVariant(lang: String, chunkMs: Int) async throws -> URL {
        let handler: DownloadUtils.ProgressHandler = { [weak self] p in
            self?.onLoadProgress?(0.97 * p.fractionCompleted)
        }
        var dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: lang, chunkMs: chunkMs, progressHandler: handler)

        // A previously interrupted download can leave a partial variant (e.g. a
        // stub encoder with no weights). Detect that and re-download cleanly.
        if !Self.variantComplete(dir) {
            try? FileManager.default.removeItem(at: dir)
            dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: lang, chunkMs: chunkMs, progressHandler: handler)
        }
        guard Self.variantComplete(dir) else { throw ASRServiceError.modelIncomplete }
        return dir
    }

    /// Whether a downloaded variant has all required files, including a fully
    /// downloaded encoder (the big ~538 MB file that gets cut off mid-download).
    static func variantComplete(_ dir: URL) -> Bool {
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(p).path) }
        guard has("metadata.json"), has("tokenizer.json"),
              has("preprocessor.mlmodelc"), has("encoder.mlmodelc") else { return false }
        let weights = dir.appendingPathComponent("encoder.mlmodelc/weights/weight.bin")
        let attrs = try? fm.attributesOfItem(atPath: weights.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return size > 50_000_000   // full encoder ~538 MB; a stub is < 4 KB
    }

    public func startStream() async throws {
        running = true
        // Resume any models kept alive from a previous meeting (no reload).
        let existing = lock.withLock { Array(pipelines.values) }
        for p in existing { await p.resume() }
        // Otherwise preload one model in the background so it's ready by the
        // time the user speaks (reduces first-caption delay).
        if existing.isEmpty { startBackgroundPreload() }
    }

    public func feed(_ chunk: AudioChunk) {
        guard running else { return }
        let pipeline: SourceASR? = lock.withLock {
            if let p = pipelines[chunk.source] { return p }
            // Pipeline still loading → ring-buffer the most recent audio so the
            // opening words aren't lost (drop oldest if the load runs long).
            var buf = pendingChunks[chunk.source] ?? []
            buf.append(chunk)
            if buf.count > maxPendingChunks { buf.removeFirst(buf.count - maxPendingChunks) }
            pendingChunks[chunk.source] = buf
            return nil
        }
        if let pipeline {
            pipeline.feed(chunk)
        } else {
            ensurePipeline(for: chunk.source)
        }
    }

    /// Release the in-memory ASR models (frees ~1 GB), e.g. before loading the
    /// summarization LLM. The next Start reloads them lazily; download is kept.
    public func releaseModels() {
        teardownAll()
    }

    public func stopStream() {
        running = false
        // Keep the loaded models in memory; just stop consuming so the next
        // Start reuses them without reloading.
        let active = lock.withLock { () -> [SourceASR] in
            pendingChunks.removeAll()
            return Array(pipelines.values)
        }
        for p in active { p.pause() }
    }

    // MARK: - Pipelines

    private func ensurePipeline(for source: AudioSourceType) {
        let shouldCreate: Bool = lock.withLock {
            guard running, variantDir != nil, pipelines[source] == nil, !creating.contains(source) else {
                return false
            }
            creating.insert(source)
            return true
        }
        guard shouldCreate else { return }

        Task { [weak self] in
            guard let self else { return }
            // Use the background-preloaded model if available (first source);
            // otherwise load one now (e.g. a second source).
            let preload = self.lock.withLock { () -> Task<StreamingNemotronMultilingualAsrManager?, Never>? in
                let t = self.warmTask; self.warmTask = nil; return t
            }
            let loaded = preload != nil ? await preload!.value : await self.loadManager()
            guard let manager = loaded else {
                self.lock.withLock { _ = self.creating.remove(source) }
                return
            }

            let pipeline = SourceASR(source: source, manager: manager)
            pipeline.onEvent = { [weak self] event in self?.onEvent?(event) }
            await pipeline.start()

            // Replay audio buffered during setup, then publish the pipeline
            // atomically (so chunks stay in order and none are dropped).
            while true {
                let batch: [AudioChunk] = self.lock.withLock {
                    let b = self.pendingChunks[source] ?? []
                    self.pendingChunks[source] = []
                    return b
                }
                if batch.isEmpty {
                    let done: Bool = self.lock.withLock {
                        guard self.pendingChunks[source]?.isEmpty ?? true else { return false }
                        if self.running { self.pipelines[source] = pipeline }
                        self.pendingChunks[source] = nil
                        self.creating.remove(source)
                        return true
                    }
                    if done {
                        if !self.running { pipeline.stop() }
                        break
                    }
                } else {
                    for c in batch { pipeline.feed(c) }
                }
            }
        }
    }

    /// Fully tear down all pipelines (used when language/tier changes).
    private func teardownAll() {
        let all = lock.withLock { () -> [SourceASR] in
            let v = Array(pipelines.values)
            pipelines.removeAll()
            creating.removeAll()
            pendingChunks.removeAll()
            warmTask?.cancel()
            warmTask = nil
            return v
        }
        for p in all { p.stop() }
    }

    // MARK: - Helpers

    static func chunkMs(for tier: String) -> Int {
        switch tier {
        case "560ms": return 560
        default: return 1120   // "1120ms" (and any legacy value) → balanced tier
        }
    }
}

public enum ASRServiceError: Error {
    case notLoaded
    case modelIncomplete
}

// MARK: - SourceASR (one streaming pipeline for a single audio source)

/// Independent streaming ASR for one audio source: owns a manager, a feed stream,
/// a consumer task, and energy-VAD utterance segmentation. Emits interim while
/// speaking and finalized when an utterance ends.
private final class SourceASR: @unchecked Sendable {
    let source: AudioSourceType
    var onEvent: ((TranscriptEvent) -> Void)?

    private let manager: StreamingNemotronMultilingualAsrManager
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var task: Task<Void, Never>?
    /// Guards `continuation`, which is read on the audio thread (`feed`) and
    /// written on the main thread (`launchConsumer` / `pause` / `stop`).
    private let lock = NSLock()

    // Energy-based VAD / utterance segmentation.
    private let voiceThreshold: Float = 0.012
    private let finalizeSilence: TimeInterval = 0.4   // finalize sooner on a pause
    private let minUtterance: TimeInterval = 0.3

    private var lastTimestamp: TimeInterval = 0
    private var utteranceStart: TimeInterval = 0
    private var lastVoiceTime: TimeInterval = 0
    private var hasSpeech = false

    init(source: AudioSourceType, manager: StreamingNemotronMultilingualAsrManager) {
        self.source = source
        self.manager = manager
    }

    func start() async {
        await manager.reset()   // clean streaming state before the first utterance
        resetState()
        await manager.setPartialCallback { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.onEvent?(.interim(text: trimmed, source: self.source, at: self.lastTimestamp))
        }
        launchConsumer()
    }

    /// Reuse the already-loaded model for a new meeting (no reload).
    func resume() async {
        await manager.reset()
        resetState()
        launchConsumer()
    }

    func feed(_ chunk: AudioChunk) {
        let cont = lock.withLock { continuation }
        cont?.yield(chunk)
    }

    /// Stop consuming but keep the model in memory for reuse.
    func pause() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    /// Permanently stop and release.
    func stop() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
        task?.cancel()
        task = nil
    }

    // MARK: - Private

    private func resetState() {
        utteranceStart = 0
        lastVoiceTime = 0
        hasSpeech = false
    }

    private func launchConsumer() {
        let stream = AsyncStream<AudioChunk> { cont in
            self.lock.withLock { self.continuation = cont }
        }
        task = Task { [weak self] in await self?.consume(stream) }
    }

    private func consume(_ stream: AsyncStream<AudioChunk>) async {
        for await chunk in stream {
            if Task.isCancelled { break }
            lastTimestamp = chunk.timestamp

            if AudioMath.isVoiced(chunk.samples, threshold: voiceThreshold) {
                if !hasSpeech { utteranceStart = chunk.timestamp }
                hasSpeech = true
                lastVoiceTime = chunk.timestamp
            }

            _ = try? await manager.process(samples: chunk.samples)

            if hasSpeech,
               (chunk.timestamp - lastVoiceTime) >= finalizeSilence,
               (lastVoiceTime - utteranceStart) >= minUtterance {
                await finalizeUtterance(at: chunk.timestamp)
            }
        }
        await finalizeUtterance(at: lastTimestamp)
    }

    private func finalizeUtterance(at endTime: TimeInterval) async {
        guard hasSpeech else { return }
        let text = (try? await manager.finish()) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onEvent?(.finalized(segment: ASRSegment(
                text: trimmed, source: source, startTime: utteranceStart, endTime: endTime
            )))
        }
        await manager.reset()
        resetState()
    }
}
