import AVFoundation
import FluidAudio
import FlowTranslateCore
import OSLog

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
///   and shared weights are reused between meetings. A summary or a changed
///   variant releases them (16 GB budget). Incoming audio is ring-buffered during
///   a cold load and replayed. `isWarm` +
///   `onModelLoading` let the UI show an honest "model loading" state meanwhile.
/// - **Language:** `setLanguage("en-US" / "sv-SE" / "auto" …)`. `en-US` (and other
///   Latin langs) use the lighter, faster "latin" ship; others/`auto` use the
///   "multilingual" ship. `auto` detects per sentence (mixed-language audio).
public final class NemotronStreamingService: ASRStreaming, @unchecked Sendable {
    private static let modelLog = Logger(subsystem: "dev.flowtranslate.app", category: "ModelStartup")
    public var onEvent: (@MainActor @Sendable (TranscriptEvent) -> Void)?
    private let delivery = TranscriptEventDelivery()
    private var creationTasks: [AudioSourceType: Task<Void, Never>] = [:]
    private var stopTask: Task<Void, Never>?
    private var stopping = false
    private var generation: UInt64 = 0
    private var weightsGeneration: UInt64 = 0
    private var configurationRequest: UInt64 = 0

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
    private var sharedLoadFailure: String?
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
    /// once ready. A prolonged cold load retains only the most recent audio.
    private var pendingChunks: [AudioSourceType: [AudioChunk]] = [:]
    private let maxPendingChunks = 200   // ~recent audio kept while the model loads
    /// Background-preloaded CoreML weights, shared by every source's manager — so
    /// running mic + system audio together costs one copy of the model, not two.
    private var sharedTask: Task<SharedNemotronMultilingualModels?, Never>?
    // Core ML may finish a cancelled load before returning. The next variant
    // waits for that native work without blocking Start or keeping old weights.
    private var nativeLoadFence: Task<Void, Never>?
    private var running = false
    private let lock = NSLock()

    private let sharedLoader: @Sendable (URL) async throws -> SharedNemotronMultilingualModels

    public init(sharedLoader: @escaping @Sendable (URL) async throws -> SharedNemotronMultilingualModels = {
        try await StreamingNemotronMultilingualAsrManager.preloadShared(from: $0)
    }) {
        self.sharedLoader = sharedLoader
    }

    /// Whether at least one streaming model is loaded in memory. When `false`
    /// right after `startStream()`, the first captions will lag behind by the
    /// model-load time. Audio buffering during that load is bounded.
    public var isWarm: Bool { lock.withLock { warm } }
    public var modelLoadFailure: String? { lock.withLock { sharedLoadFailure } }

    // MARK: - ASRStreaming

    /// Ensure the model for the current language + tier is downloaded and valid
    /// (re-downloads a partial/corrupt cache). Fast when already cached. The model
    /// is loaded into memory lazily on first audio. No-op if already prepared.
    public func loadModels(tier: String) async throws {
        let request = lock.withLock { configurationRequest &+= 1; return configurationRequest }
        let language = currentLanguage
        await waitForStopUnlessCancelled()
        try Task.checkCancellation()
        await prepareDiarizationIfNeeded(request: request)
        try Task.checkCancellation()
        guard lock.withLock({ configurationRequest == request }) else { throw CancellationError() }
        let key = "\(language)|\(tier)"
        if lock.withLock({ loadedKey == key && variantDir != nil }) { return }

        // Only DOWNLOAD here (fast when cached). The model is loaded into memory
        // lazily on the first audio chunk, while incoming audio is buffered — so
        // Start stays responsive; the UI asks users to wait for readiness.
        let directory = try await ensureVariant(lang: language, chunkMs: Self.chunkMs(for: tier))
        try Task.checkCancellation()
        guard selectVariant(directory: directory, key: key, request: request) else { throw CancellationError() }
        onLoadProgress?(1.0)
    }

    /// Download and load the pyannote 3.1 pipeline independently of ASR. Diarization
    /// is optional, so a model failure is surfaced to the UI but never prevents
    /// captions (fail-open).
    private func prepareDiarizationIfNeeded(request: UInt64) async {
        guard diarizationEnabled else {
            lock.withLock {
                if configurationRequest == request { diarizerModels = nil }
            }
            return
        }
        guard lock.withLock({ configurationRequest == request && diarizerModels == nil }) else { return }
        do {
            let progress: DownloadUtils.ProgressHandler = { [weak self] p in
                self?.onDiarizationLoadProgress?(p.fractionCompleted)
            }
            let models = try await DiarizerModels.downloadIfNeeded(progressHandler: progress)
            guard !Task.isCancelled else { return }
            let installed = lock.withLock {
                guard configurationRequest == request else { return false }
                diarizerModels = models
                return true
            }
            if installed { onDiarizationLoadProgress?(1.0) }
        } catch {
            onDiarizationUnavailable?("pyannote diarization unavailable: \(error.localizedDescription)")
        }
    }

    /// Load the weights in the background now, so they're ready by the time the
    /// user speaks (overlaps the multi-second load with user prep → less
    /// first-caption delay). Every source that needs a pipeline shares them.
    private func startBackgroundPreload() {
        lock.withLock {
            if sharedLoadFailure != nil {
                weightsGeneration &+= 1
                sharedLoadFailure = nil
                sharedTask = nil
            }
            guard sharedTask == nil, pipelines.isEmpty else { return }
            _ = sharedLoadLocked()
        }
    }

    /// Called under `lock`, so all sources and presets use one native loader.
    private func sharedLoadLocked() -> Task<SharedNemotronMultilingualModels?, Never> {
        if let sharedTask { return sharedTask }
        let previous = nativeLoadFence
        let load = Task { [weak self] () -> SharedNemotronMultilingualModels? in
            await previous?.value
            guard !Task.isCancelled else { return nil }
            return await self?.loadShared()
        }
        sharedTask = load
        nativeLoadFence = Task { _ = await load.value }
        return load
    }

    /// Load the CoreML weights once, for every source to share. Respects task
    /// cancellation (a cancelled warm preload stops early instead of finishing a
    /// multi-second CoreML load whose result is discarded).
    private func loadShared() async -> SharedNemotronMultilingualModels? {
        let (directory, token) = lock.withLock { (variantDir, weightsGeneration) }
        guard let dir = directory, !Task.isCancelled else { return nil }
        let began = ContinuousClock.now
        Self.modelLog.notice("Core ML weight load started")
        onModelLoading?(true)
        defer {
            if lock.withLock({ weightsGeneration == token }) { onModelLoading?(false) }
        }
        let shared: SharedNemotronMultilingualModels
        do {
            shared = try await sharedLoader(dir)
        } catch {
            guard !Task.isCancelled else { return nil }
            lock.withLock {
                if weightsGeneration == token { sharedLoadFailure = error.localizedDescription }
            }
            Self.modelLog.error("Core ML weight load failed after \(String(describing: ContinuousClock.now - began), privacy: .public)")
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard lock.withLock({ () -> Bool in
            guard weightsGeneration == token else { return false }
            warm = true
            return true
        }) else { return nil }
        Self.modelLog.notice("Core ML weights ready after \(String(describing: ContinuousClock.now - began), privacy: .public)")
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

    /// Prepare a dictation variant only while idle. A newer preparation or
    /// stream invalidates this request, so a late download cannot reconfigure it.
    public func prewarmVariant(language: String, tier: String) async {
        guard let request = beginIdlePreparation() else { return }
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
        guard !Task.isCancelled,
              selectVariant(directory: dir, key: "\(language)|\(tier)", request: request) else { return }
        startBackgroundPreload()
    }

    /// Prepare the selected installed variant without starting capture.
    /// Missing files are handled by the app's download prompt.
    @discardableResult
    func prewarmCachedVariant(language: String, tier: String) -> Bool {
        let directory = Self.variantDirectory(language: language, tier: tier)
        guard Self.variantComplete(directory), let request = beginIdlePreparation(),
              selectVariant(directory: directory, key: "\(language)|\(tier)", request: request)
        else { return false }
        startBackgroundPreload()
        return true
    }

    private func beginIdlePreparation() -> UInt64? {
        lock.withLock {
            guard !running, !stopping else { return nil }
            configurationRequest &+= 1
            return configurationRequest
        }
    }

    private func selectVariant(directory: URL, key: String, request: UInt64) -> Bool {
        let selection = lock.withLock { () -> (Bool, [SourceASR]) in
            guard configurationRequest == request, !running, !stopping else { return (false, []) }
            // Language selection belongs to each decoder. The on-disk variant
            // identifies the weights shared by languages in the same ship/tier.
            let old = variantDir != directory
                ? removePipelinesLocked(freeingWeights: true) : []
            variantDir = directory
            loadedKey = key
            return (true, old)
        }
        for pipeline in selection.1 { pipeline.stop() }
        return selection.0
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
        if let task, await CancellableTaskWait.wait(for: task), await task.value == nil {
            // A failed load is not a reusable model. Keep an in-progress load
            // on caller cancellation, but let the next attempt retry a failure.
            lock.withLock { if sharedTask == task { sharedTask = nil } }
        }
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
        variantComplete(variantDirectory(language: language, tier: tier))
    }

    private static func variantDirectory(language: String, tier: String) -> URL {
        fluidModels
            .appendingPathComponent("nemotron-multilingual", isDirectory: true)
            .appendingPathComponent(shipDirectory(for: language), isDirectory: true)
            .appendingPathComponent("\(chunkMs(for: tier))ms", isDirectory: true)
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
        await waitForStopUnlessCancelled()
        try Task.checkCancellation()
        lock.withLock {
            stopTask = nil
            stopping = false
            generation &+= 1
            configurationRequest &+= 1
            running = true
        }
        // Preload one model in the background so it's ready by the time the user
        // speaks (overlaps the multi-second load with user prep). Pipelines are
        // created lazily per source on the first audio chunk.
        startBackgroundPreload()
    }

    public func feed(_ chunk: AudioChunk) {
        let pipeline: SourceASR? = lock.withLock {
            guard running, sharedLoadFailure == nil else { return nil }
            if let p = pipelines[chunk.source] { return p }
            // Pipeline still loading → ring-buffer the most recent audio so the
            // recent audio can be replayed (drop oldest if the load runs long).
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
        lock.withLock {
            configurationRequest &+= 1
            diarizerModels = nil
        }
        teardownAll()
    }

    /// Stop consuming audio.
    ///
    /// - Parameter keepModelsResident: leave the loaded weights in memory for the
    ///   next stream instead of freeing them.
    ///
    /// Interactive sessions retain shared weights to avoid another native load.
    /// Their per-source decoder state is always discarded after draining; a new
    /// variant, summary, or explicit release frees the shared weights as well.
    public func stopStream() { stopStream(keepModelsResident: false) }

    public func stopStream(keepModelsResident: Bool) {
        lock.withLock {
            guard stopTask == nil else { return }
            running = false
            stopping = true
            let token = generation
            for pipeline in pipelines.values { pipeline.finishInput() }
            stopTask = Task { [self] in
                // A cold pipeline may still own the opening audio. Let setup
                // finish and replay it before closing its consumer.
                let creating = lock.withLock { Array(creationTasks.values) }
                for task in creating { await task.value }
                guard !Task.isCancelled else { return }
                let active = lock.withLock { generation == token ? Array(pipelines.values) : [] }
                for pipeline in active { await pipeline.finishAndDrain() }
                await delivery.drain()
                teardownPipelines(freeingWeights: !keepModelsResident, expectedGeneration: token)
            }
        }
    }

    public func drain() async {
        let task = lock.withLock { stopTask }
        await task?.value
    }

    private func waitForStopUnlessCancelled() async {
        let task = lock.withLock { stopTask }
        if let task { _ = await CancellableTaskWait.wait(for: task) }
    }

    /// Cancellation discards abandoned input. It never joins a cold CoreML
    /// load, and generation checks reject every late pipeline/event from it.
    /// Deliberate meeting Stop continues to use stopStreamAndDrain instead.
    public func cancelStream(keepModelsResident: Bool = false) {
        teardownPipelines(freeingWeights: !keepModelsResident, cancellingSession: true)
    }

    public func stopStreamAndDrain() async {
        stopStream()
        await drain()
    }

    // MARK: - Pipelines

    private func ensurePipeline(for source: AudioSourceType) {
        lock.withLock {
            guard running, variantDir != nil, sharedLoadFailure == nil,
                  pipelines[source] == nil, !creating.contains(source) else {
                return
            }
            creating.insert(source)
            let token = generation
            creationTasks[source] = Task { [weak self] in
            guard let self else { return }
            // Every source awaits the SAME weight-load task: the first one starts
            // it (or reuses the warm preload), later ones adopt the result instead
            // of loading a second copy of the model.
            let load = self.lock.withLock { () -> Task<SharedNemotronMultilingualModels?, Never>? in
                guard !Task.isCancelled, self.generation == token else { return nil }
                return self.sharedLoadLocked()
            }
            guard let load else { return }
            let shared = await load.value
            guard !Task.isCancelled, self.lock.withLock({ self.generation == token }) else { return }
            guard let shared, let manager = await self.makeManager(from: shared) else {
                self.lock.withLock {
                    if self.generation == token { _ = self.creating.remove(source) }
                }
                return
            }
            guard !Task.isCancelled, self.lock.withLock({ self.generation == token }) else { return }

            let pipeline = SourceASR(
                source: source, manager: manager,
                tuning: .forSource(source, scenario: self.scenario),
                keepAcousticContext: self.keepAcousticContext)
            pipeline.configureDiarization(enabled: self.diarizationEnabled,
                                          models: self.lock.withLock { self.diarizerModels },
                                          config: self.diarizerConfig)
            pipeline.onEvent = { [weak self] event in
                guard let self else { return }
                self.delivery.send(event) { [weak self] event in
                    guard let self, self.lock.withLock({ self.generation == token }),
                          let handler = self.onEvent else { return }
                    handler(event)
                }
            }
            pipeline.onVadUnavailable = { [weak self] msg in self?.onVadUnavailable?(msg) }
            await pipeline.start()
            guard !Task.isCancelled, self.lock.withLock({ self.generation == token }) else {
                pipeline.stop()
                return
            }

            // Replay audio buffered during setup, then publish the pipeline
            // atomically (so chunks stay in order and none are dropped).
            while true {
                let batch: [AudioChunk] = self.lock.withLock {
                    guard self.generation == token else { return [] }
                    let b = self.pendingChunks[source] ?? []
                    self.pendingChunks[source] = []
                    return b
                }
                if batch.isEmpty {
                    let done: Bool = self.lock.withLock {
                        guard self.generation == token else { return true }
                        guard self.pendingChunks[source]?.isEmpty ?? true else { return false }
                        if self.running || self.stopping { self.pipelines[source] = pipeline }
                        self.pendingChunks[source] = nil
                        self.creating.remove(source)
                        return true
                    }
                    if done {
                        let state = self.lock.withLock { (self.generation == token, self.running) }
                        if !state.0 { pipeline.stop() }
                        else if !state.1 { pipeline.finishInput() }
                        break
                    }
                } else {
                    for c in batch { pipeline.feed(c) }
                }
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
    private func teardownPipelines(freeingWeights: Bool = false,
                                   expectedGeneration: UInt64? = nil,
                                   cancellingSession: Bool = false) {
        let all = lock.withLock { () -> [SourceASR] in
            if let expectedGeneration, generation != expectedGeneration { return [] }
            generation &+= 1
            if cancellingSession {
                configurationRequest &+= 1
                running = false
                stopping = false
                stopTask?.cancel()
                stopTask = nil
            }
            if expectedGeneration != nil { stopping = false }
            return removePipelinesLocked(freeingWeights: freeingWeights)
        }
        for p in all { p.stop() }
    }

    /// Caller holds `lock`; identity and the actual shared weights change as one
    /// operation. Prewarming must never relabel old weights as a new variant.
    private func removePipelinesLocked(freeingWeights: Bool) -> [SourceASR] {
        generation &+= 1
        let v = Array(pipelines.values)
        pipelines.removeAll()
        creating.removeAll()
        for task in creationTasks.values { task.cancel() }
        creationTasks.removeAll()
        pendingChunks.removeAll()
        if freeingWeights {
            weightsGeneration &+= 1
            sharedTask?.cancel()
            sharedTask = nil      // drops the shared weights → memory freed
            warm = false
            sharedLoadFailure = nil
        }
        return v
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
    private var utteranceId = UUID()
    private var hasSpeech = false
    private var lastPartial = ""   // live partial, for terminal-punctuation close

    // Optional speaker diarization (pyannote 3.1 + WeSpeaker). Each source keeps
    // its own diarizer + speaker database so mic and system identities never mix.
    private var diarizer: DiarizerManager?
    private let speakerFinalizer = SpeakerFinalizationQueue()
    private var diarizationAudio: [Float] = []
    private var diarizationAudioStartTime: TimeInterval?
    private var asrAudioStartTime: TimeInterval?
    private var diarizationBufferSamples: Int { Int((tuning.maxSpeech + 2) * 16_000) }
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
            config: .init(minSpeech: tuning.minSpeech, maxSpeech: tuning.maxSpeech,
                          semanticGrace: max(0.45, tuning.minSilence),
                          extendUnpunctuatedSpeech: tuning == .video))
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
            self.onEvent?(.interim(text: trimmed, source: self.source, at: self.lastTimestamp,
                                   utteranceId: self.utteranceId))
        }
        launchConsumer()
    }

    func feed(_ chunk: AudioChunk) {
        let cont = lock.withLock { continuation }
        cont?.yield(chunk)
    }

    /// Each source pipeline owns its speaker database so labels remain stable
    /// without mixing microphone and system-audio identities.
    func configureDiarization(enabled: Bool, models: DiarizerModels?, config: DiarizerConfig) {
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
        speakerFinalizer.cancel()
    }

    func finishInput() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    func finishAndDrain() async {
        finishInput()
        await task?.value
        await speakerFinalizer.drain()
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
        utteranceId = UUID()
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
            lastTimestamp = chunk.timestamp + Double(chunk.samples.count) / 16_000

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
            let started = sawStart || (!endpointer.inUtterance && !lastPartial.isEmpty)
            let dt = Double(chunk.samples.count) / 16_000.0
            let wasActive = endpointer.inUtterance
            let events = endpointer.process(
                speechStarted: started, speechEnded: ended, partial: lastPartial, dt: dt)
            if wasActive, !endpointer.inUtterance, events.isEmpty {
                await endUtterance()
            }
            for event in events {
                switch event {
                case .start:
                    utteranceStart = chunk.timestamp
                    hasSpeech = true
                case .finalize:
                    await finalizeUtterance(at: lastTimestamp)
                }
            }
        }
        if !Task.isCancelled { await finalizeUtterance(at: lastTimestamp) }
    }

    private func finalizeUtterance(at endTime: TimeInterval) async {
        guard hasSpeech else { return }
        let result = try? await manager.finishWithTokenTimings()
        guard !Task.isCancelled else { return }
        let trimmed = (result?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await endUtterance()
            return
        }

        let fallback = ASRSegment(text: trimmed, source: source, startTime: utteranceStart,
                                  endTime: endTime, utteranceId: utteranceId)
        guard diarizer != nil else {
            onEvent?(.finalized(segment: fallback))
            await endUtterance()
            return
        }
        let audio = speakerAudio(from: utteranceStart, to: endTime)
        let origin = asrAudioStartTime ?? utteranceStart
        let tokens = (result?.timings ?? []).map {
            TimedTextToken(
                text: $0.token,
                startTime: origin + $0.startTime,
                endTime: origin + $0.endTime)
        }
        onEvent?(.previewFinal(fallback))
        speakerFinalizer.submit(fallback: fallback, analyze: { [weak self] in
            self?.speakerSegments(for: fallback, audio: audio, tokens: tokens) ?? [fallback]
        }, deliver: { [weak self] segments in
            if segments.count == 1, let segment = segments.first {
                self?.onEvent?(.finalized(segment: segment))
            } else {
                self?.onEvent?(.finalizedGroups(segments))
            }
        })
        await endUtterance()
    }

    private func speakerSegments(
        for fallback: ASRSegment, audio: SpeakerAudio?, tokens: [TimedTextToken]
    ) -> [ASRSegment] {
        let startTime = fallback.startTime, endTime = fallback.endTime
        let turns = audio.map { diarizationTurns($0, from: startTime, to: endTime) } ?? []
        // A diarization gap at the start of an utterance is common for short
        // speech. Only two measured speakers justify splitting the decoded text.
        let aligned = turns.isEmpty ? [] : SpeakerTurnAligner.align(tokens: tokens, turns: turns)
        let measuredSpeakers = Set(aligned.compactMap(\.speakerLabel))

        // Every label leaves through `continuity`, so a short utterance the
        // diarizer declined to segment inherits the current speaker instead of
        // going out unlabelled. See `SpeakerContinuity`: pyannote returns no
        // speaker below `minSpeechDuration`, which is exactly what "對" / "OK" /
        // a backchannel is, and those were losing their name every time.
        if measuredSpeakers.count <= 1 {
            let start = aligned.first?.startTime ?? startTime
            let end = aligned.last?.endTime ?? endTime
            let resolved = measuredSpeakers.first
                ?? dominantSpeaker(in: turns, from: startTime, to: endTime)
            return [ASRSegment(
                text: fallback.text, source: source, startTime: start, endTime: end,
                speakerLabel: continuity.label(resolved, from: start, to: end),
                utteranceEndTime: endTime, utteranceId: fallback.utteranceId
            )]
        }
        return aligned.enumerated().map { index, group in
            ASRSegment(
                text: group.text, source: source,
                startTime: group.startTime, endTime: group.endTime,
                speakerLabel: continuity.label(group.speakerLabel, from: group.startTime, to: group.endTime),
                utteranceEndTime: endTime,
                position: index == aligned.count - 1 ? .lastGroup : .earlierGroup,
                utteranceId: fallback.utteranceId
            )
        }
    }

    private struct SpeakerAudio: Sendable {
        let samples: [Float]
        let startTime: TimeInterval
    }

    /// pyannote consumes raw PCM around the utterance; its ten-second inference
    /// windows are independent of Nemotron's chunk tier and finalization points.
    private func speakerAudio(from startTime: TimeInterval, to endTime: TimeInterval) -> SpeakerAudio? {
        guard let bufferStart = diarizationAudioStartTime else { return nil }
        let contextStart = max(bufferStart, startTime - Self.diarizationPreRoll)
        let startIndex = min(diarizationAudio.count, max(0, Int((contextStart - bufferStart) * 16_000)))
        let endIndex = min(diarizationAudio.count, max(startIndex, Int((endTime - bufferStart) * 16_000)))
        guard endIndex > startIndex else { return nil }
        return SpeakerAudio(samples: Array(diarizationAudio[startIndex..<endIndex]),
                            startTime: bufferStart + Double(startIndex) / 16_000)
    }

    private func diarizationTurns(_ audio: SpeakerAudio, from startTime: TimeInterval,
                                  to endTime: TimeInterval) -> [SpeakerTurn] {
        guard let diarizer, let result = try? diarizer.performCompleteDiarization(
            audio.samples, sampleRate: 16_000, atTime: audio.startTime) else { return [] }

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
