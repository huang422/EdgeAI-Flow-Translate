import AVFoundation
import FluidAudio
import FlowTranslateCore

/// Streaming ASR over FluidAudio's multilingual Nemotron‑3.5 model (CoreML/ANE).
///
/// Key design points:
/// - **One independent pipeline per audio source.** A streaming ASR keeps
///   continuous acoustic state, so feeding system audio and microphone audio into
///   a single model corrupts it (slow / garbled / no output). Each source gets its
///   own `StreamingNemotronMultilingualAsrManager` + Silero VAD + utterance state.
///   The heavy CoreML **weights are shared** between those managers, though: the
///   per-stream state (encoder state, caches, prediction buffers) is what must be
///   private, not the ~633 MB of read-only weights.
/// - **Memory policy.** The downloaded variant is cached on disk (no re-download),
///   but the in-memory models are RELEASED at meeting end (16 GB budget) and
///   lazily reloaded on the next Start — incoming audio is ring-buffered during
///   the load and replayed, so the opening words are never lost. `isWarm` +
///   `onModelLoading` let the UI show an honest "model loading" state meanwhile.
/// - **Language:** `setLanguage("en-US" / "sv-SE" / "auto" …)`. `en-US` (and other
///   Latin langs) use the lighter, faster "latin" ship; others/`auto` use the
///   "multilingual" ship. `auto` detects per sentence (mixed-language audio).
public final class NemotronStreamingService: ASRStreaming, @unchecked Sendable {
    public var onEvent: ((TranscriptEvent) -> Void)?

    /// First-caption language hint (Nemotron locale, e.g. "en-US", or "auto").
    public var currentLanguage: String = SupportedASRLanguages.default

    /// What the system audio is (video vs. live meeting speech). Applied to each
    /// source pipeline at start/resume; the microphone always uses the meeting
    /// profile (see `SegmentationTuning.forSource`).
    public var scenario: CaptureScenario = .video

    /// Reports model load/download progress (0…1) during `loadModels`.
    public var onLoadProgress: ((Double) -> Void)?

    /// Called with an error message if the Silero VAD model fails to load. The
    /// pipeline still runs (max-speech flush only) but the caller should warn.
    public var onVadUnavailable: ((String) -> Void)?

    /// Called true when a model starts loading lazily, false when it's ready.
    public var onModelLoading: ((Bool) -> Void)?

    /// Enables pyannote/speaker-diarization-3.1 for each active audio source.
    public var diarizationEnabled = false

    /// Experimental: carry the encoder's acoustic context across sentence
    /// boundaries instead of resetting at each finalize. Applied on the next Start.
    public var keepAcousticContext = false

    /// Reports pyannote/WeSpeaker download and load progress (0...1).
    public var onDiarizationLoadProgress: ((Double) -> Void)?

    /// Reports a recoverable diarization failure. ASR continues without labels.
    public var onDiarizationUnavailable: ((String) -> Void)?

    private var variantDir: URL?
    private var loadedKey: String?        // "<language>|<tier>" currently downloaded
    private var pipelines: [AudioSourceType: SourceASR] = [:]
    private var creating: Set<AudioSourceType> = []
    /// True once at least one streaming model is resident in memory (the warm
    /// preload or a pipeline load finished). Drives the UI's "warming" state so
    /// it can show an honest "model loading" instead of a premature "Listening".
    private var warm = false
    /// How readily the diarizer splits one voice into two. Applied on the next
    /// `loadModels`, like every other segmentation setting.
    public var diarizationSensitivity: DiarizationSensitivity = .balanced

    /// pyannote/WeSpeaker tuning.
    ///
    /// The two failure modes pull in opposite directions — over-segmentation
    /// ("two people, four speakers") and under-segmentation — so every value here
    /// stays at the library's default rather than half of it:
    ///
    /// - `minSpeechDuration: 1.0` gates *creating* a speaker. Half a second does
    ///   not produce a stable WeSpeaker embedding, and one that lands far from
    ///   everything mints a brand-new person. At 1.0 a segment that short returns
    ///   no speaker and inherits the previous label — what the aligner's
    ///   `previousLabel` fallback is for.
    /// - `minEmbeddingUpdateDuration: 2.0` so only substantial speech moves a
    ///   stored centroid. Letting second-long fragments drag it makes an
    ///   established speaker drift out from under their own later segments.
    /// - `chunkDuration: 10.0`, because pyannote 3.1's segmentation model is
    ///   trained on 10-second windows and halving that halves the context it has
    ///   for deciding where one voice stops and another starts.
    /// - `clusteringThreshold` comes from the sensitivity setting, because no
    ///   single value serves both rooms. FluidAudio derives the speaker-assignment
    ///   threshold from it, and its 0.7 default yields 0.84 — 29% looser than the
    ///   0.65 `SpeakerManager` documents, which crowds five voices into two.
    private var diarizerConfig: DiarizerConfig {
        DiarizerConfig(
            clusteringThreshold: diarizationSensitivity.clusteringThreshold,
            minSpeechDuration: 1.0,
            minEmbeddingUpdateDuration: 2.0,
            chunkDuration: 10.0)
    }
    private var diarizerModels: DiarizerModels?
    /// Audio captured while a source's pipeline is still being created, replayed
    /// once it's ready so the opening words are never dropped (cold-start fix).
    private var pendingChunks: [AudioSourceType: [AudioChunk]] = [:]
    private let maxPendingChunks = 200   // ~recent audio kept while the model loads
    /// Background-preloaded CoreML weights, shared by every source's manager — so
    /// running mic + system audio together costs one copy of the model, not two.
    private var sharedTask: Task<SharedNemotronMultilingualModels?, Never>?
    private var running = false
    private let lock = NSLock()

    public init() {}

    /// Whether at least one streaming model is loaded in memory. When `false`
    /// right after `startStream()`, the first captions will lag behind by the
    /// model-load time (incoming audio is buffered, so no words are lost).
    public var isWarm: Bool { lock.withLock { warm } }

    // MARK: - ASRStreaming

    /// Ensure the model for the current language + tier is downloaded and valid
    /// (re-downloads a partial/corrupt cache). Fast when already cached. The model
    /// is loaded into memory lazily on first audio. No-op if already prepared.
    public func loadModels(tier: String) async throws {
        await prepareDiarizationIfNeeded()
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

    /// Download and load the pyannote 3.1 pipeline independently of ASR. Diarization
    /// is optional, so a model failure is surfaced to the UI but never prevents
    /// captions (fail-open).
    private func prepareDiarizationIfNeeded() async {
        guard diarizationEnabled else {
            diarizerModels = nil
            return
        }
        guard diarizerModels == nil else { return }
        do {
            let progress: DownloadUtils.ProgressHandler = { [weak self] p in
                self?.onDiarizationLoadProgress?(p.fractionCompleted)
            }
            diarizerModels = try await DiarizerModels.downloadIfNeeded(
                progressHandler: progress)
            onDiarizationLoadProgress?(1.0)
        } catch {
            onDiarizationUnavailable?("pyannote diarization unavailable: \(error.localizedDescription)")
        }
    }

    /// Load the weights in the background now, so they're ready by the time the
    /// user speaks (overlaps the multi-second load with user prep → less
    /// first-caption delay). Every source that needs a pipeline shares them.
    private func startBackgroundPreload() {
        lock.withLock {
            guard sharedTask == nil, pipelines.isEmpty else { return }
            sharedTask = Task { [weak self] in await self?.loadShared() ?? nil }
        }
    }

    /// Load the CoreML weights once, for every source to share. Respects task
    /// cancellation (a cancelled warm preload stops early instead of finishing a
    /// multi-second CoreML load whose result is discarded).
    private func loadShared() async -> SharedNemotronMultilingualModels? {
        guard let dir = variantDir, !Task.isCancelled else { return nil }
        onModelLoading?(true)
        defer { onModelLoading?(false) }
        guard let shared = try? await StreamingNemotronMultilingualAsrManager
            .preloadShared(from: dir)                    // CoreML load + ANE warm-up
        else { return nil }
        guard !Task.isCancelled else { return nil }
        lock.withLock { warm = true }
        return shared
    }

    /// Build + language-configure one streaming manager over the shared weights.
    /// `loadFromShared` adopts the `MLModel` references — which are safe for
    /// concurrent `prediction(from:)` — while giving this manager its own encoder
    /// state, caches and prediction buffers, so the two sources can never corrupt
    /// each other's acoustic state.
    private func makeManager(
        from shared: SharedNemotronMultilingualModels
    ) async -> StreamingNemotronMultilingualAsrManager? {
        let m = StreamingNemotronMultilingualAsrManager()
        do {
            try await m.loadFromShared(shared)
        } catch {
            return nil
        }
        await m.setLanguage(currentLanguage)
        // Language lock (P0): when the user picked a SPECIFIC language, seed the
        // decoder with its lang-tag token (Whisper-style forced prefix) so the
        // multilingual model can't drift or mis-detect mid-meeting. "auto" keeps
        // per-sentence detection for mixed-language audio.
        if currentLanguage != "auto" {
            await m.setForcedPrefix(true)
        }
        return m
    }

    /// Fetch and verify a variant **without touching the live configuration**.
    ///
    /// `loadModels` writes `currentLanguage`/`loadedKey` and tears down the
    /// running pipelines, so it cannot be used to get ahead of a dictation that
    /// has not started — it would reconfigure a recognizer a meeting may be
    /// using. This only ensures the files are on disk and validated, which is the
    /// part that makes the first ⌃⌥Space wait.
    ///
    /// Costs no memory: weights are loaded lazily on the first audio chunk.
    public func prewarmVariant(language: String, tier: String) async {
        guard let dir = try? await ensureVariant(
            lang: language, chunkMs: Self.chunkMs(for: tier)
        ) else { return }
        // Files on disk are not the wait. The weights load into the ANE on the
        // **first audio chunk** — several seconds — which is why the first
        // ⌃⌥Space after idle misses the opening words while a meeting never
        // does: a meeting shows "Loading" and the user waits for "Listening"
        // before speaking, and its own preload has already run.
        //
        // Loading them here is what actually makes the hotkey ready. It is the
        // same shared load every source adopts, so a meeting started afterwards
        // reuses it rather than paying twice.
        // `variantDir` and `loadedKey` are written together, to **this** variant.
        // They are one fact in two fields — the files, and the language/tier that
        // `loadModels` compares against — so setting either alone made them
        // describe different variants, and clearing the key instead made the next
        // `loadModels` tear down the weights this method had just compiled.
        lock.withLock {
            variantDir = dir
            loadedKey = "\(language)|\(tier)"
        }
        startBackgroundPreload()
    }

    /// Wait until the weights are resident, so a caller can say "ready" honestly.
    ///
    /// `loadModels` only fetches files; the CoreML load and the ANE compile
    /// happen on the first audio chunk, several seconds later. A meeting can
    /// absorb that — it shows "載入模型", buffers the audio and replays it — but
    /// dictation cannot: the user presses a key, sees "聆聽中", speaks, and the
    /// recognizer is not there yet. Awaiting the preload moves that wait in front
    /// of the panel's own loading state, where it is visible and expected.
    public func warmUpWeights() async {
        startBackgroundPreload()
        let task = lock.withLock { sharedTask }
        _ = await task?.value
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

    /// FluidAudio's on-disk model root (ASR variants + Silero VAD live here).
    private static var fluidModels: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// True if at least one full ASR variant is cached (so launch needs no download).
    /// Variants live two levels deep: nemotron-multilingual/<ship>/<chunkMs>.
    public static var asrModelPresent: Bool {
        let base = fluidModels.appendingPathComponent("nemotron-multilingual")
        let fm = FileManager.default
        guard let ships = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        else { return false }
        return ships.contains { ship in
            (try? fm.contentsOfDirectory(at: ship, includingPropertiesForKeys: nil))?
                .contains { variantComplete($0) } ?? false
        }
    }

    /// Whether the variant for a SPECIFIC language + tier is fully cached.
    /// `asrModelPresent` only proves that *some* variant exists — after the user
    /// switches the first-caption language or the ASR tier, the next Start may
    /// still need a ~600 MB download; this is the check that predicts it.
    public static func variantPresent(language: String, tier: String) -> Bool {
        let ship = shipDirectory(for: language)
        let dir = fluidModels
            .appendingPathComponent("nemotron-multilingual", isDirectory: true)
            .appendingPathComponent(ship, isDirectory: true)
            .appendingPathComponent("\(chunkMs(for: tier))ms", isDirectory: true)
        return variantComplete(dir)
    }

    /// Mirror of FluidAudio's ship-selection rule (latin vs. multilingual), kept
    /// in sync with `StreamingNemotronMultilingualAsrManager.languageDirectory`.
    static func shipDirectory(for languageCode: String) -> String {
        let c = languageCode.lowercased()
        let latinPrefixes = ["en", "es", "fr", "it", "pt", "de"]
        return latinPrefixes.contains(where: { c.hasPrefix($0) }) ? "latin" : "multilingual"
    }

    /// True if the Silero VAD CoreML model is cached.
    public static var vadModelPresent: Bool {
        FileManager.default.fileExists(atPath: fluidModels
            .appendingPathComponent("silero-vad/silero-vad-unified-256ms-v6.0.0.mlmodelc").path)
    }

    /// True when the pyannote segmentation and WeSpeaker embedding models are cached.
    public static var diarizationModelPresent: Bool {
        let directory = DiarizerModels.defaultModelsDirectory()
        return DiarizerModels.requiredModelNames.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Download the Silero VAD model now (no-op if cached). `false` on failure.
    /// The presence check avoids loading the whole CoreML model into memory (and
    /// immediately discarding it) just to prove the files are on disk.
    public func prefetchVAD() async -> Bool {
        if Self.vadModelPresent { return true }
        return await SileroEndpointer() != nil
    }

    public func startStream() async throws {
        running = true
        // Preload one model in the background so it's ready by the time the user
        // speaks (overlaps the multi-second load with user prep). Pipelines are
        // created lazily per source on the first audio chunk.
        startBackgroundPreload()
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
        diarizerModels = nil
    }

    /// Stop consuming audio.
    ///
    /// - Parameter keepModelsResident: leave the loaded weights in memory for the
    ///   next stream instead of freeing them.
    ///
    /// A meeting frees them: it is a long session, it ends deliberately, and the
    /// ~600 MB is worth returning. **Dictation must not.** It is seconds long and
    /// happens repeatedly, and tearing down at the end of one meant the next
    /// ⌃⌥Space paid the CoreML load and the ANE compile again — several seconds
    /// before the recognizer could hear a word, every single time. That is the
    /// "第二次辨識又要再載入一次" report, and it is this line that caused it.
    ///
    /// What is torn down instead is the *pipeline* — the per-source decoder state
    /// — which is cheap to rebuild and must not carry acoustic state from one
    /// dictation into the next. Only the shared weights survive.
    public func stopStream() { stopStream(keepModelsResident: false) }

    public func stopStream(keepModelsResident: Bool) {
        running = false
        // The consumers' trailing finalize still runs (`stop()` only cancels the
        // loop), and the caller's drain window collects that last sentence.
        if keepModelsResident {
            teardownPipelines()
        } else {
            teardownAll()
        }
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
            // Every source awaits the SAME weight-load task: the first one starts
            // it (or reuses the warm preload), later ones adopt the result instead
            // of loading a second copy of the model.
            let load = self.lock.withLock { () -> Task<SharedNemotronMultilingualModels?, Never> in
                if let t = self.sharedTask { return t }
                let t = Task { [weak self] in await self?.loadShared() ?? nil }
                self.sharedTask = t
                return t
            }
            let shared = await load.value
            if shared == nil {
                // Drop the failed task so the NEXT source (or the next chunk that
                // re-triggers this path) actually retries. Caching a completed
                // task that yielded nil would keep handing every later attempt
                // the same failure — one transient CoreML hiccup would leave the
                // whole meeting with no captions at all.
                self.lock.withLock { if self.sharedTask == load { self.sharedTask = nil } }
            }
            guard let shared, let manager = await self.makeManager(from: shared) else {
                self.lock.withLock { _ = self.creating.remove(source) }
                return
            }

            let pipeline = SourceASR(
                source: source, manager: manager,
                tuning: .forSource(source, scenario: self.scenario),
                keepAcousticContext: self.keepAcousticContext)
            pipeline.configureDiarization(enabled: self.diarizationEnabled,
                                          models: self.diarizerModels,
                                          config: self.diarizerConfig)
            pipeline.onEvent = { [weak self] event in self?.onEvent?(event) }
            pipeline.onVadUnavailable = { [weak self] msg in self?.onVadUnavailable?(msg) }
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
        teardownPipelines(freeingWeights: true)
    }

    /// Drop the per-source decoders, and optionally the weights behind them.
    ///
    /// The two are separable and it matters which is which. A **pipeline** holds
    /// one source's encoder state, caches and prediction buffers; it is cheap,
    /// and it must not survive from one session to the next or the next one
    /// starts mid-sentence in the previous one's acoustic context. The **shared
    /// weights** are the ~600 MB and the seconds of ANE compile; they are
    /// identical for every session on the same variant, so freeing them between
    /// two dictations is pure loss.
    private func teardownPipelines(freeingWeights: Bool = false) {
        let all = lock.withLock { () -> [SourceASR] in
            let v = Array(pipelines.values)
            pipelines.removeAll()
            creating.removeAll()
            pendingChunks.removeAll()
            if freeingWeights {
                sharedTask?.cancel()
                sharedTask = nil      // drops the shared weights → memory freed
                warm = false
            }
            return v
        }
        for p in all { p.stop() }
    }

    // MARK: - Helpers

    static func chunkMs(for tier: String) -> Int {
        switch tier {
        case "560ms": return 560
        // FluidAudio's own default: highest throughput, and WER neutral against
        // the other two on its benchmark. Not a "quality tier" — see
        // `PromptDictation.tier` for the numbers.
        case "2240ms": return 2240
        default: return 1120         // "1120ms" (and any legacy value) → balanced tier
        }
    }
}

public enum ASRServiceError: Error {
    case notLoaded
    case modelIncomplete
}

// MARK: - SourceASR (one streaming pipeline for a single audio source)

/// Independent streaming ASR for one audio source: owns a manager, a feed stream,
/// a consumer task, and Silero-VAD utterance segmentation. Emits interim while
/// speaking and finalized when an utterance ends.
private final class SourceASR: @unchecked Sendable {
    let source: AudioSourceType
    var onEvent: ((TranscriptEvent) -> Void)?
    var onVadUnavailable: ((String) -> Void)?

    private let manager: StreamingNemotronMultilingualAsrManager
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var task: Task<Void, Never>?
    /// Guards `continuation`, which is read on the audio thread (`feed`) and
    /// written on the main thread (`launchConsumer` / `pause` / `stop`).
    private let lock = NSLock()

    // Utterance segmentation: Silero VAD drives starts/endpoints; the pure
    // Endpointer only drops sub-minSpeech blips and force-flushes at maxSpeech.
    // Timing comes from the scenario tuning (video vs. meeting; mic = meeting).
    private var tuning: SegmentationTuning
    private var endpointer: Endpointer
    private var silero: SileroEndpointer?
    private var vadWarned = false

    private var lastTimestamp: TimeInterval = 0
    private var utteranceStart: TimeInterval = 0
    private var hasSpeech = false
    private var lastPartial = ""   // live partial, for terminal-punctuation close

    // Optional speaker diarization (pyannote 3.1 + WeSpeaker). Each source keeps
    // its own diarizer + speaker database so mic and system identities never mix.
    private var diarizationEnabled = false
    private var diarizer: DiarizerManager?
    private var diarizationAudio: [Float] = []
    private var diarizationAudioStartTime: TimeInterval?
    private var asrAudioStartTime: TimeInterval?
    private let diarizationBufferSamples = 12 * 16_000
    /// How far a chunk's timestamp may sit from the end of the buffered audio
    /// before the run is treated as broken.
    ///
    /// Wider than one chunk at any tier (2240 ms is the longest) so ordinary
    /// jitter never re-origins the buffer, and far below the gap a dropped chunk
    /// opens.
    private static let diarizationContinuityTolerance: TimeInterval = 2.5
    /// Holds the current speaker across an utterance pyannote could not label.
    private var continuity = SpeakerContinuity()

    /// Experimental: carry the encoder's acoustic context across sentences.
    private let keepAcousticContext: Bool

    init(source: AudioSourceType, manager: StreamingNemotronMultilingualAsrManager,
         tuning: SegmentationTuning, keepAcousticContext: Bool = false) {
        self.source = source
        self.manager = manager
        self.tuning = tuning
        self.keepAcousticContext = keepAcousticContext
        self.endpointer = Endpointer(
            config: .init(minSpeech: tuning.minSpeech, maxSpeech: tuning.maxSpeech))
    }

    func start() async {
        await manager.reset()   // clean streaming state before the first utterance
        resetDiarization()
        await ensureSilero()
        resetState()
        await manager.setPartialCallback { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.lastPartial = trimmed
            self.onEvent?(.interim(text: trimmed, source: self.source, at: self.lastTimestamp))
        }
        launchConsumer()
    }

    // (The old resume()/pause() keep-alive pair was removed: endMeeting always
    // releases the models on a 16 GB budget, so the path was unreachable.)

    func feed(_ chunk: AudioChunk) {
        let cont = lock.withLock { continuation }
        cont?.yield(chunk)
    }

    /// Each source pipeline owns its speaker database so labels remain stable
    /// without mixing microphone and system-audio identities.
    func configureDiarization(enabled: Bool, models: DiarizerModels?, config: DiarizerConfig) {
        diarizationEnabled = enabled
        guard enabled, let models else {
            diarizer = nil
            diarizationAudio.removeAll(keepingCapacity: false)
            diarizationAudioStartTime = nil
            return
        }
        let instance = DiarizerManager(config: config)
        instance.initialize(models: models)
        diarizer = instance
    }

    /// Permanently stop and release. The consumer task is cancelled (its loop
    /// breaks at the next chunk) but the trailing finalize still emits, so the
    /// sentence in flight when Stop was pressed reaches the transcript.
    func stop() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
        task?.cancel()
        task = nil
    }

    // MARK: - Private

    /// Close out an utterance: drop the model's streaming state, or keep it.
    ///
    /// `manager.reset()` clears the encoder cache (3.36 s of left context), the
    /// decoder LSTM and `absoluteFrameBase`, so the next sentence starts cold.
    /// Keeping it hands the model real acoustic history — at the cost of the
    /// language-lock re-seed and a decoder that may run the new sentence on as a
    /// continuation of the last. Hence opt-in.
    ///
    /// The reset and the timing origin MUST move together. Token times are
    /// `asrAudioStartTime + timing.startTime`, and `timing.startTime` counts from
    /// `absoluteFrameBase`. Resetting zeroes the frame base, so the origin has to
    /// be re-taken from the next chunk; keeping it means the origin has to be
    /// kept too — otherwise every later sentence's timestamps collapse back to
    /// the start of the stream and speaker alignment silently breaks.
    private func endUtterance() async {
        if !keepAcousticContext { await manager.reset() }
        resetState(keepingAudioOrigin: keepAcousticContext)
    }

    private func resetState(keepingAudioOrigin: Bool = false) {
        utteranceStart = 0
        hasSpeech = false
        lastPartial = ""
        if !keepingAudioOrigin { asrAudioStartTime = nil }
        endpointer.reset()
    }

    private func resetDiarization() {
        diarizer?.speakerManager.reset()
        diarizationAudio.removeAll(keepingCapacity: true)
        diarizationAudioStartTime = nil
        // The speaker database is gone, so the name held over from the last
        // meeting refers to nobody.
        continuity.reset()
    }

    /// Load the Silero VAD once. Fail loud: on failure warn the caller (no silent
    /// energy fallback); the pipeline then finalizes only on the maxSpeech cap.
    private func ensureSilero() async {
        guard silero == nil else { return }
        silero = await SileroEndpointer(tuning: tuning)
        if silero == nil, !vadWarned {
            vadWarned = true
            onVadUnavailable?("Silero VAD unavailable — captions run in degraded mode.")
        }
    }

    /// How many audio chunks may wait for the recognizer.
    ///
    /// `AsyncStream` defaults to `.unbounded`, and the producer here is a
    /// real-time audio callback that can never block: every chunk the recognizer
    /// has not consumed yet is simply queued. Under normal operation the queue is
    /// one or two deep, but the recognizer stalls for real — a model load, a
    /// diarizer inference, thermal throttling — and an unbounded queue turns a
    /// stall into permanent lag, because the backlog is audio the app must still
    /// process before it can reach the present. Captions would drift further
    /// behind for the rest of the meeting and never recover, while the queue
    /// itself grows without limit.
    ///
    /// 256 chunks is roughly 20–60 seconds of audio depending on the capture
    /// buffer size — far beyond any stall the app recovers from, so it never
    /// engages in normal use. Past it the **oldest** audio is dropped, which is
    /// the right end to lose: a live caption for speech a minute old has no value,
    /// and holding it delays every word after it.
    private static let audioQueueLimit = 256

    private func launchConsumer() {
        let stream = AsyncStream<AudioChunk>(bufferingPolicy: .bufferingNewest(Self.audioQueueLimit)) {
            cont in
            self.lock.withLock { self.continuation = cont }
        }
        task = Task { [weak self] in await self?.consume(stream) }
    }

    private func consume(_ stream: AsyncStream<AudioChunk>) async {
        for await chunk in stream {
            if Task.isCancelled { break }
            lastTimestamp = chunk.timestamp

            // Keep a rolling PCM window for pyannote (independent of Nemotron's
            // chunk tier; its 5 s inference windows need raw audio context).
            if diarizer != nil {
                // Re-origin the buffer whenever the incoming audio is not
                // contiguous with what is already in it.
                //
                // `diarizationTurns` converts an absolute time to a sample index
                // by assuming the buffer is one unbroken run starting at
                // `diarizationAudioStartTime`. The **microphone stream is not**:
                // `CaptureViewModel`'s echo suppression drops every mic chunk that
                // arrives while system audio is playing, and the pipeline's
                // bounded queue drops chunks under load. Timestamps are wall
                // clock, so each dropped chunk widens the gap between "seconds
                // since the buffer started" and "samples in the buffer".
                //
                // Once that gap exceeds the buffer's own span, the computed
                // `startIndex` reaches `count`, the `endIndex > startIndex` guard
                // fails and the whole utterance comes back with **no turns** —
                // which is the speaker label silently disappearing. It gets worse
                // the longer a meeting runs and the more the other side talks,
                // which is exactly the reported "sometimes, and then more often".
                //
                // Restarting the run costs the diarizer some left context for one
                // utterance; carrying on with a corrupt index costs the label
                // outright, for every utterance after the drift sets in.
                let expectedNext = (diarizationAudioStartTime ?? chunk.timestamp)
                    + Double(diarizationAudio.count) / 16_000.0
                if diarizationAudioStartTime == nil
                    || abs(chunk.timestamp - expectedNext) > Self.diarizationContinuityTolerance {
                    diarizationAudio.removeAll(keepingCapacity: true)
                    diarizationAudioStartTime = chunk.timestamp
                }
                diarizationAudio.append(contentsOf: chunk.samples)
                if diarizationAudio.count > diarizationBufferSamples {
                    let removed = diarizationAudio.count - diarizationBufferSamples
                    diarizationAudio.removeFirst(removed)
                    diarizationAudioStartTime? += Double(removed) / 16_000.0
                }
            }

            if asrAudioStartTime == nil { asrAudioStartTime = chunk.timestamp }

            _ = try? await manager.process(samples: chunk.samples)

            // Silero VAD start/end events for this chunk drive segmentation. We open
            // an utterance on a Silero start OR as soon as the ASR emits partial text
            // (lastPartial is non-empty only within an active, unfinalized utterance).
            // The partial-text trigger keeps the wall-clock maxSpeech firing — so
            // captions still split — even when Silero emits no start (degraded /
            // VAD-unavailable mode), WITHOUT opening an empty utterance during
            // silence, which would backdate the segment's start time. VAD end
            // splits earlier.
            var sawStart = false, ended = false
            if let silero {
                for e in await silero.events(for: chunk.samples) {
                    if e.isStart { sawStart = true } else if e.isEnd { ended = true }
                }
            }
            let started = sawStart || !lastPartial.isEmpty

            let dt = Double(chunk.samples.count) / 16_000.0
            let sentenceEnded = Endpointer.endsSentence(lastPartial)
            let sentenceIncomplete = SemanticEndpoint.isIncomplete(lastPartial)
            // A fragment that is complete-sounding but too short to be a sentence
            // — "然後", "好的" before a thinking pause — buys the same one-window
            // grace as an unfinished thought. An *empty* partial buys nothing:
            // see `isTooShortToClose`.
            let tooShort = Endpointer.isTooShortToClose(lastPartial)
            for event in endpointer.process(
                speechStarted: started, speechEnded: ended, sentenceEnded: sentenceEnded,
                sentenceIncomplete: sentenceIncomplete, tooShort: tooShort, dt: dt
            ) {
                switch event {
                case .start:
                    utteranceStart = chunk.timestamp
                    hasSpeech = true
                case .finalize:
                    await finalizeUtterance(at: chunk.timestamp)
                }
            }
        }
        await finalizeUtterance(at: lastTimestamp)
    }

    private func finalizeUtterance(at endTime: TimeInterval) async {
        guard hasSpeech else { return }
        let result = try? await manager.finishWithTokenTimings()
        let trimmed = (result?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await endUtterance()
            return
        }

        let turns = diarizationTurns(from: utteranceStart, to: endTime)
        let origin = asrAudioStartTime ?? utteranceStart
        let tokens = (result?.timings ?? []).map {
            TimedTextToken(
                text: $0.token,
                startTime: origin + $0.startTime,
                endTime: origin + $0.endTime)
        }
        // Preserve Nemotron's exact decoded text when diarization is disabled or
        // unavailable; token-piece reconstruction is only needed to split turns.
        let aligned = turns.isEmpty ? [] : SpeakerTurnAligner.align(tokens: tokens, turns: turns)

        // Every label leaves through `continuity`, so a short utterance the
        // diarizer declined to segment inherits the current speaker instead of
        // going out unlabelled. See `SpeakerContinuity`: pyannote returns no
        // speaker below `minSpeechDuration`, which is exactly what "對" / "OK" /
        // a backchannel is, and those were losing their name every time.
        if aligned.isEmpty {
            let resolved = dominantSpeaker(in: turns, from: utteranceStart, to: endTime)
            onEvent?(.finalized(segment: ASRSegment(
                text: trimmed, source: source, startTime: utteranceStart, endTime: endTime,
                speakerLabel: continuity.label(resolved, from: utteranceStart, to: endTime)
            )))
        } else {
            for group in aligned {
                onEvent?(.finalized(segment: ASRSegment(
                    text: group.text,
                    source: source,
                    startTime: group.startTime,
                    endTime: group.endTime,
                    speakerLabel: continuity.label(
                        group.speakerLabel, from: group.startTime, to: group.endTime)
                )))
            }
        }
        await endUtterance()
    }

    /// pyannote consumes raw PCM around the utterance; its ten-second inference
    /// windows are independent of Nemotron's chunk tier and finalization points.
    private func diarizationTurns(from startTime: TimeInterval, to endTime: TimeInterval) -> [SpeakerTurn] {
        guard diarizationEnabled else { return [] }
        guard let diarizer, let bufferStart = diarizationAudioStartTime, !diarizationAudio.isEmpty else {
            return []
        }

        let contextStart = max(bufferStart, startTime - Self.diarizationPreRoll)
        let startIndex = min(diarizationAudio.count, max(0, Int((contextStart - bufferStart) * 16_000)))
        let endIndex = min(diarizationAudio.count, max(startIndex, Int((endTime - bufferStart) * 16_000)))
        guard endIndex > startIndex else { return [] }
        let audio = Array(diarizationAudio[startIndex..<endIndex])
        guard let result = try? diarizer.performCompleteDiarization(
            audio, sampleRate: 16_000, atTime: contextStart) else { return [] }

        // Resolve the labels BEFORE compacting the database.
        //
        // `mergeSpeaker` deletes the source speaker, so a segment id resolved
        // afterwards would come back nil and fall through to `"Speaker <id>"` —
        // a raw numeric label that the naming layer reads as a speaker it has
        // never seen. A pass meant to remove a phantom would have minted one.
        let turns = result.segments.compactMap { segment -> SpeakerTurn? in
            // Turns lying entirely inside the pre-roll belong to whoever spoke
            // *before* this utterance. They are fed to the model on purpose —
            // segmentation needs some left context — but attributing this
            // utterance's words to them is exactly backwards, and the aligner's
            // midpoint fallback will happily do it when a token has no overlap.
            let turnStart = Double(segment.startTimeSeconds)
            let turnEnd = Double(segment.endTimeSeconds)
            guard turnEnd > startTime, turnStart < endTime else { return nil }
            return SpeakerTurn(
                label: diarizer.speakerManager.getSpeaker(for: segment.speakerId)?.name
                    ?? "Speaker \(segment.speakerId)",
                startTime: turnStart,
                endTime: turnEnd)
        }

        compactSpeakers(diarizer)
        return turns
    }

    /// Fold back together speakers that have since converged.
    ///
    /// Without this an over-segmentation is permanent: a phantom speaker minted
    /// from one bad embedding stays in the database for the whole meeting, even
    /// once its centroid has drifted onto the person it was split from and
    /// `findMergeablePairs` would say the two are the same voice. This is what
    /// lets a meeting recover from a bad first minute.
    ///
    /// Merging uses the **embedding** threshold, not the assignment one. They
    /// answer different questions: assignment asks whether one short segment
    /// belongs to a known voice, and is deliberately generous because the
    /// alternative is inventing a speaker. Merging asks whether two speakers who
    /// have each accumulated minutes of audio are the same person, and being
    /// wrong there silently attributes one person's words to another for the rest
    /// of the meeting. The tighter threshold is the one FluidAudio already uses
    /// to decide an embedding is trustworthy enough to update a stored centroid.
    /// The direction of each merge is chosen here rather than taken from
    /// `findMergeablePairs`, which picks it from dictionary key order: the
    /// survivor keeps its name, so an arbitrary direction can delete the name the
    /// user has been reading for ten minutes. Keeping whichever speaker has more
    /// audio folds the phantom into the established person — the better embedding
    /// and the name already on screen.
    private func compactSpeakers(_ diarizer: DiarizerManager) {
        let threshold = diarizer.speakerManager.embeddingThreshold
        for pair in diarizer.speakerManager.findMergeablePairs(speakerThreshold: threshold) {
            let candidate = diarizer.speakerManager.getSpeaker(for: pair.speakerToMerge)
            let destination = diarizer.speakerManager.getSpeaker(for: pair.destination)
            // A pair may already be gone: the list is computed against one
            // snapshot and an earlier merge in this loop can delete a member.
            // `mergeSpeaker` no-ops on a missing id, so this stays safe.
            guard let candidate, let destination else { continue }
            if candidate.duration > destination.duration {
                diarizer.speakerManager.mergeSpeaker(destination.id, into: candidate.id)
            } else {
                diarizer.speakerManager.mergeSpeaker(candidate.id, into: destination.id)
            }
        }
    }

    /// Audio before the utterance handed to pyannote as left context.
    ///
    /// The segmentation model needs some, but every extra second is another
    /// second of the *previous* speaker being re-embedded into the database — and
    /// in a two-person conversation the previous speaker is always the other
    /// person. One second was enough to re-embed a whole turn boundary on every
    /// single utterance.
    private static let diarizationPreRoll: TimeInterval = 0.5

    private func dominantSpeaker(
        in turns: [SpeakerTurn], from startTime: TimeInterval, to endTime: TimeInterval
    ) -> String? {
        var totals: [String: TimeInterval] = [:]
        for turn in turns {
            totals[turn.label, default: 0] += max(
                0, min(endTime, turn.endTime) - max(startTime, turn.startTime))
        }
        return totals.max { $0.value < $1.value }?.key
    }
}
