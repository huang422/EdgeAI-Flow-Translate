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
    private let diarizerConfig = DiarizerConfig(
        minSpeechDuration: 0.5,
        minEmbeddingUpdateDuration: 1.0,
        chunkDuration: 5.0)
    private var diarizerModels: DiarizerModels?
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
    /// Respects task cancellation (a cancelled warm preload stops early instead
    /// of finishing a multi-second CoreML load whose result is discarded).
    private func loadManager() async -> StreamingNemotronMultilingualAsrManager? {
        guard let dir = variantDir, !Task.isCancelled else { return nil }
        onModelLoading?(true)
        defer { onModelLoading?(false) }
        let m = StreamingNemotronMultilingualAsrManager()
        do {
            try await m.loadModels(from: dir)   // CoreML load + ANE warm-up
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        await m.setLanguage(currentLanguage)
        // Language lock (P0): when the user picked a SPECIFIC language, seed the
        // decoder with its lang-tag token (Whisper-style forced prefix) so the
        // multilingual model can't drift or mis-detect mid-meeting. "auto" keeps
        // per-sentence detection for mixed-language audio.
        if currentLanguage != "auto" {
            await m.setForcedPrefix(true)
        }
        lock.withLock { warm = true }
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

    public func stopStream() {
        running = false
        // Meetings always release models at Stop (endMeeting → releaseModels), so
        // there is no keep-alive path: tear the pipelines down here as well. The
        // consumers' trailing finalize still runs (stop() only cancels the loop),
        // and the caller's drain window collects that last sentence.
        teardownAll()
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

            let pipeline = SourceASR(
                source: source, manager: manager,
                tuning: .forSource(source, scenario: self.scenario))
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
        let all = lock.withLock { () -> [SourceASR] in
            let v = Array(pipelines.values)
            pipelines.removeAll()
            creating.removeAll()
            pendingChunks.removeAll()
            warmTask?.cancel()
            warmTask = nil
            warm = false
            return v
        }
        for p in all { p.stop() }
    }

    // MARK: - Helpers

    static func chunkMs(for tier: String) -> Int {
        switch tier {
        case "560ms": return 560
        case "2240ms": return 2240   // FluidAudio's recommended quality tier
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

    init(source: AudioSourceType, manager: StreamingNemotronMultilingualAsrManager,
         tuning: SegmentationTuning) {
        self.source = source
        self.manager = manager
        self.tuning = tuning
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

    private func resetState() {
        utteranceStart = 0
        hasSpeech = false
        lastPartial = ""
        asrAudioStartTime = nil
        endpointer.reset()
    }

    private func resetDiarization() {
        diarizer?.speakerManager.reset()
        diarizationAudio.removeAll(keepingCapacity: true)
        diarizationAudioStartTime = nil
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

            // Keep a rolling PCM window for pyannote (independent of Nemotron's
            // chunk tier; its 5 s inference windows need raw audio context).
            if diarizer != nil {
                if diarizationAudioStartTime == nil { diarizationAudioStartTime = chunk.timestamp }
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
            // VAD-unavailable mode), WITHOUT opening an empty utterance during silence
            // (which used to backdate the segment's start time). VAD end splits earlier.
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
            for event in endpointer.process(
                speechStarted: started, speechEnded: ended, sentenceEnded: sentenceEnded,
                sentenceIncomplete: sentenceIncomplete, dt: dt
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
            await manager.reset()
            resetState()
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

        if aligned.isEmpty {
            onEvent?(.finalized(segment: ASRSegment(
                text: trimmed, source: source, startTime: utteranceStart, endTime: endTime,
                speakerLabel: dominantSpeaker(in: turns, from: utteranceStart, to: endTime)
            )))
        } else {
            for group in aligned {
                onEvent?(.finalized(segment: ASRSegment(
                    text: group.text,
                    source: source,
                    startTime: group.startTime,
                    endTime: group.endTime,
                    speakerLabel: group.speakerLabel
                )))
            }
        }
        await manager.reset()
        resetState()
    }

    /// pyannote consumes raw PCM around the utterance; its five-second inference
    /// windows are independent of Nemotron's chunk tier and finalization points.
    private func diarizationTurns(from startTime: TimeInterval, to endTime: TimeInterval) -> [SpeakerTurn] {
        guard diarizationEnabled else { return [] }
        guard let diarizer, let bufferStart = diarizationAudioStartTime, !diarizationAudio.isEmpty else {
            return []
        }

        let contextStart = max(bufferStart, startTime - 1.0)
        let startIndex = min(diarizationAudio.count, max(0, Int((contextStart - bufferStart) * 16_000)))
        let endIndex = min(diarizationAudio.count, max(startIndex, Int((endTime - bufferStart) * 16_000)))
        guard endIndex > startIndex else { return [] }
        let audio = Array(diarizationAudio[startIndex..<endIndex])
        guard let result = try? diarizer.performCompleteDiarization(
            audio, sampleRate: 16_000, atTime: contextStart) else { return [] }

        return result.segments.map { segment in
            SpeakerTurn(
                label: diarizer.speakerManager.getSpeaker(for: segment.speakerId)?.name
                    ?? "Speaker \(segment.speakerId)",
                startTime: Double(segment.startTimeSeconds),
                endTime: Double(segment.endTimeSeconds))
        }
    }

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
