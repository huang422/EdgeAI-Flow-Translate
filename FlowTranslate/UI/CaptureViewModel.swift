import Foundation
import Combine
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import Translation
import OSLog
import FlowTranslateCore

struct CaptionLine: Identifiable, Equatable {
    let id: UUID
    var english: String
    var chinese: String?
    /// Which audio source produced this line (drives the leading source-colour dot).
    var source: AudioSourceType = .system
    /// Wall-clock time the line was finalized (shown as a transcript timestamp).
    var timestamp: Date = Date()
}

/// Wires audio capture → Nemotron ASR → translation → bilingual captions /
/// transcript / summary (P1–P4 integration).
@MainActor
final class CaptureViewModel: ObservableObject {
    static let log = Logger(subsystem: "dev.flowtranslate.app", category: "model")

    // Audio sources
    @Published var micEnabled = false
    @Published var systemEnabled = false
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0

    // Recognition / captions
    @Published var asrState: ASRState = .idle {
        didSet { overlay.model.listenState = asrState.overlayListenState }
    }
    @Published var interimText = ""
    @Published var interimChinese = ""
    @Published var lines: [CaptionLine] = []
    @Published var statusMessage = "Idle"

    // Meeting / summary / overlay
    /// Single source of truth for overlay visibility. Both the UI switch and the
    /// ⌃⌥C hotkey set this; `didSet` shows/hides the (single, reused) panel — so the
    /// switch and hotkey can never desync or stack two overlays.
    @Published var overlayOn = false {
        didSet {
            guard oldValue != overlayOn else { return }
            if overlayOn { overlay.show() } else { overlay.hide() }
        }
    }
    @Published var summaryText = ""
    @Published var isSummarizing = false

    /// Human-readable second-caption status (language pair + translation method).
    @Published var translationStatus = ""

    /// Model download/prefetch status (e.g. the Qwen model fetched at Start).
    @Published var modelStatus = ""

    /// True when a required model is missing at launch — the UI shows a one-time
    /// download prompt so the first meeting isn't blocked by a surprise download.
    @Published var showModelDownloadPrompt = false
    /// True while the launch-time bulk download runs.
    @Published var isDownloadingModels = false

    enum TranslationMethod { case none, apple, mlx }
    private var translationMethod: TranslationMethod = .apple
    /// Single shared Qwen model, reused by live translation and the post-meeting
    /// summary — loaded into memory at most once.
    private let qwenHost = QwenModelHost()
    private lazy var mlxTranslator = MLXTranslator(host: qwenHost)
    /// Rolling source-sentence context for the on-device Qwen translator so the
    /// second caption stays coherent across lines (pronouns, recurring terms).
    /// Reset at the start of each session and when the language pair changes.
    private let mlxContext = ContextBuffer(capacity: 3)

    // In-flight on-device (Qwen/MLX) translations, keyed by sentence id. Tracked so
    // `endMeeting()` can wait for any running GPU generation to finish BEFORE the
    // shared Qwen model is unloaded — otherwise `MLXMemory.reclaim()` would call
    // `GPU.clearCache()` mid-generation (a documented crash hazard). `accepting-
    // Translations` gates new ones so none can start once the meeting is stopping.
    private var inflightTranslations: [UUID: Task<Void, Never>] = [:]
    private var acceptingTranslations = true

    // Echo suppression: when system audio is playing through speakers, the mic
    // mostly hears that same audio → skip mic input to avoid garbled double
    // captions. (Accessed from the audio threads, so lock-protected.)
    private let echoLock = NSLock()
    private var lastSystemVoiceAt = Date.distantPast
    private var systemSourceOn = false

    // Serializes translation-backend resolution (avoids overlapping availability
    // checks when settings change rapidly).
    private var availabilityTask: Task<Void, Never>?
    // Lazy Qwen memory-load: started by the first sentence that needs the model
    // (during a meeting), never at app launch. Shared so concurrent sentences
    // load it once. The files are pre-downloaded to disk at meeting Start.
    private var qwenLoadTask: Task<Void, Never>?
    // Background download-to-disk of the Qwen model, kicked off at meeting Start
    // (like the ASR model) so there's no surprise download mid-meeting.
    private var qwenPrefetchTask: Task<Void, Never>?

    /// Free the Qwen model from **memory** and reset its load state. The disk
    /// prefetch is intentionally left running — the summary needs those files even
    /// after translation switches to Apple or the meeting ends.
    private func unloadQwen() {
        qwenHost.unload()         // frees the container + returns the MLX cache to the OS
        qwenLoadTask?.cancel(); qwenLoadTask = nil
    }

    /// Cancel and await every in-flight on-device translation so no GPU generation
    /// is still running when the Qwen model is unloaded and its MLX cache cleared.
    private func drainInflightTranslations() async {
        let tasks = Array(inflightTranslations.values)
        inflightTranslations.removeAll()
        for t in tasks { t.cancel() }
        for t in tasks { await t.value }
    }

    /// At meeting Start, download the Qwen model files to disk in the background
    /// (like the ASR model). Always runs: even if translation uses Apple, the
    /// end-of-meeting **summary** uses the same Qwen model. Memory load stays lazy.
    /// The translator and summarizer share the same model id, so this one download
    /// serves both. Download-only — no memory is used until something loads it.
    private func prefetchQwen() {
        guard !qwenHost.isComplete, qwenPrefetchTask == nil else { return }
        qwenPrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Clear the handle when done so a later Start can resume an incomplete
            // download (the downloader skips files already fetched at full size).
            defer { self.qwenPrefetchTask = nil }
            do {
                try await self.qwenHost.prefetch { p in
                    Task { @MainActor in
                        self.modelStatus = "下載 Qwen 模型（翻譯／摘要用）… \(Int(p * 100))%"
                    }
                }
                self.modelStatus = "Qwen 模型已下載（用到時載入記憶體）"
            } catch {
                Self.log.error("Qwen prefetch failed: \(String(reflecting: error), privacy: .public)")
                self.modelStatus = "Qwen 模型下載失敗：\(String(describing: error))"
            }
        }
    }

    /// Load the Qwen model into memory on demand (guarded so it loads exactly
    /// once), showing live progress. Files are normally already on disk (fetched
    /// at Start), so this is just a memory load. Returns whether the model is ready.
    private func ensureQwenReady(srcName: String, tgtName: String) async -> Bool {
        if qwenHost.isLoaded { return true }
        if qwenLoadTask == nil {
            qwenLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.translationStatus = "翻譯語言：\(srcName) → \(tgtName) · Qwen 模型載入中…"
                // Wait for the at-Start disk prefetch (if any) so we don't download twice.
                await self.qwenPrefetchTask?.value
                do {
                    try await self.qwenHost.ensureLoaded { p in
                        Task { @MainActor in
                            self.translationStatus = "翻譯語言：\(srcName) → \(tgtName) · Qwen 模型載入中… \(Int(p * 100))%"
                        }
                    }
                    self.translationStatus = "翻譯語言：\(srcName) → \(tgtName) · Qwen 模型翻譯（已載入）"
                } catch {
                    Self.log.error("Qwen load failed: \(String(reflecting: error), privacy: .public)")
                    self.translationStatus = "翻譯語言：Qwen 載入失敗（\(String(describing: error))），輸入語言正常"
                }
            }
        }
        await qwenLoadTask?.value
        return qwenHost.isLoaded
    }

    // User settings (persisted). Applied to the live pipeline on change.
    @Published var settings: CaptionSettings = SettingsStore.load() {
        didSet { applySettings() }
    }

    enum ASRState: Equatable {
        case idle, loading, listening

        /// Map to the overlay's status so the idle pill reflects reality instead of
        /// always claiming "Listening".
        var overlayListenState: OverlayListenState {
            switch self {
            case .idle:      return .idle
            case .loading:   return .loading
            case .listening: return .listening
            }
        }
    }

    // Dependencies
    private let router = AudioRouter()
    private let asr = NemotronStreamingService()
    let translation = TranslationService()
    let overlay = OverlayController()
    private let store: TranscriptStoring
    private let cleaner = BasicTextCleaner()
    // MLX Qwen3-4B summarizer (on-demand), with the pure-Swift extractive
    // summarizer as an offline / failure fallback.
    private lazy var mlxSummarizer = MLXMeetingSummarizer(host: qwenHost)
    private let fallbackSummarizer = ExtractiveSummarizer()
    private var segmentIndex = 0
    private var lastSummaryEN: Summary?
    private var lastSummaryZH: Summary?
    /// Id of the sentence currently shown in the floating overlay, so a late
    /// translation only updates the overlay if it still belongs to that sentence.
    private var currentOverlayId: UUID?

    // Live (interim) translation: translate the in-progress sentence on a
    // throttle so the second caption updates in real time, not only on finalize.
    private var currentInterimId: UUID?
    private var pendingInterimText: String?
    private var lastInterimTranslateAt: Date = .distantPast
    private var interimThrottleTask: Task<Void, Never>?
    private var interimInFlight = false
    private let interimTranslateInterval: TimeInterval = 0.2
    /// Audio source of the current interim line (drives the overlay source dot).
    private var currentInterimSource: AudioSourceType = .system
    /// Read-only accessor for the UI (updates alongside the published `interimText`).
    var currentInterimSourceForUI: AudioSourceType { currentInterimSource }

    init() {
        // Bound the MLX Metal cache up front so freed Qwen weights / KV caches are
        // returned to the OS instead of lingering (the main memory-bloat fix).
        MLXMemory.configureAtLaunch()

        // Persist the transcript to Application Support so an unexpected close
        // does not lose accumulated segments (FR-008).
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FlowTranslate", isDirectory: true)
        store = (try? FileTranscriptStore(directory: dir)) ?? InMemoryTranscriptStore()

        router.onChunk = { [weak self] chunk in
            guard let self else { return }
            let rms = AudioMath.rms(chunk.samples)
            // Always update the level meter (independent of recognition).
            Task { @MainActor in self.updateLevel(chunk.source, rms) }

            let voiced = rms >= 0.012
            if chunk.source == .system {
                if voiced { self.echoLock.withLock { self.lastSystemVoiceAt = Date() } }
                self.asr.feed(chunk)
            } else {
                // Microphone: while system audio is actively playing, what the mic
                // hears is mostly the speakers (echo) → drop it so the same content
                // isn't transcribed twice / garbled. Use the system track instead.
                let systemActiveNow = self.echoLock.withLock {
                    Date().timeIntervalSince(self.lastSystemVoiceAt) < 0.8
                }
                if self.systemSourceOn && systemActiveNow { return }
                self.asr.feed(chunk)
            }
        }
        asr.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        asr.onModelLoading = { [weak self] loading in
            Task { @MainActor in
                guard let self, self.asrState == .listening else { return }
                self.statusMessage = loading
                    ? "辨識模型載入中…（首次較久，請開始說話）"
                    : "辨識中 Listening"
            }
        }
        asr.onVadUnavailable = { [weak self] msg in
            Task { @MainActor in self?.statusMessage = "⚠️ " + msg }
        }
        translation.onResult = { [weak self] id, zh in
            self?.applyTranslation(id: id, chinese: zh)
        }
        translation.onUnavailable = { [weak self] in
            self?.statusMessage = "翻譯語言包未安裝，請在彈出視窗允許下載 (System Settings > Translation Languages)"
        }
        // Persist a dragged overlay position / font step made from the overlay's own
        // hover controls.
        overlay.onPositionChanged = { [weak self] origin in
            self?.settings.overlayPosition = origin
        }
        overlay.onFontStep = { [weak self] delta in
            self?.stepOverlayFont(delta)
        }
        overlay.onReset = { [weak self] in
            self?.resetOverlaySettings()
        }
        applySettings()
        registerGlobalShortcuts()
    }

    /// Global shortcuts (work even while another app like Zoom is focused).
    /// ⌃⌥C overlay · ⌃⌥= / ⌃⌥- font size · ⌃⌥P pin (spec §2.8).
    private func registerGlobalShortcuts() {
        let mod = controlKey | optionKey
        let center = GlobalHotKeyCenter.shared
        center.register(keyCode: kVK_ANSI_C, modifiers: mod) { [weak self] in
            Task { @MainActor in self?.toggleOverlay() }
        }
        center.register(keyCode: kVK_ANSI_Equal, modifiers: mod) { [weak self] in
            Task { @MainActor in self?.stepOverlayFont(1) }
        }
        center.register(keyCode: kVK_ANSI_Minus, modifiers: mod) { [weak self] in
            Task { @MainActor in self?.stepOverlayFont(-1) }
        }
        center.register(keyCode: kVK_ANSI_P, modifiers: mod) { [weak self] in
            Task { @MainActor in self?.overlay.togglePin() }
        }
    }

    /// Step the overlay font size by ±2pt (clamped), persisting via settings.
    func stepOverlayFont(_ delta: Int) {
        let next = (settings.overlayFontSize + Double(delta) * 2)
        let clamped = min(max(next, CaptionTheme.Metric.fontMin), CaptionTheme.Metric.fontMax)
        guard clamped != settings.overlayFontSize else { return }
        settings.overlayFontSize = clamped
    }

    // MARK: - Settings

    private func applySettings() {
        translation.enabled = settings.needsTranslation
        // "auto" first-caption → let the translator auto-detect the source.
        translation.sourceLanguage = settings.firstLanguage == "auto"
            ? "" : String(settings.firstLanguage.prefix(2))
        translation.targetLanguage = settings.secondLanguage.rawValue
        overlay.applySettings(settings)
        SettingsStore.save(settings)
        availabilityTask?.cancel()
        availabilityTask = Task { await updateTranslationAvailability() }
    }

    /// Pick the translation backend for the current language pair and update the
    /// live status line. **Apple** (fast, on-device) for a specific source it
    /// supports; the **MLX Qwen** model for "auto" (Apple can't auto-detect) and
    /// for specific pairs Apple doesn't support.
    private func updateTranslationAvailability() async {
        let tgtName = settings.secondLanguage.displayName

        // Off vs. same-language: distinct, clear messages (was a confusing "關閉").
        guard settings.secondCaptionEnabled else {
            translationMethod = .none; translation.enabled = false; unloadQwen()
            translationStatus = "翻譯語言：已關閉"
            return
        }
        guard settings.needsTranslation else {
            translationMethod = .none; translation.enabled = false; unloadQwen()
            translationStatus = "翻譯語言：來源與目標同為「\(tgtName)」，無需翻譯（請改選不同的目標語言）"
            return
        }

        // Choose the backend. Apple needs a KNOWN source: for "auto" it can't,
        // and pops up a system "choose a language" sheet, so auto always uses the
        // on-device Qwen model. A specific language uses Apple when it supports the
        // pair (covers most languages on macOS 26), else falls back to Qwen.
        let srcName: String
        let useQwen: Bool
        if settings.firstLanguage == "auto" {
            srcName = "自動偵測"
            useQwen = true
        } else {
            srcName = settings.firstLanguage
            let source = Locale.Language(identifier: String(settings.firstLanguage.prefix(2)))
            let target = Locale.Language(identifier: settings.secondLanguage.rawValue)
            useQwen = await LanguageAvailability().status(from: source, to: target) == .unsupported
        }

        if !useQwen {
            translationMethod = .apple
            translation.enabled = true
            unloadQwen()
            translationStatus = "翻譯語言：\(srcName) → \(tgtName) · Apple 系統翻譯（即時）"
            return
        }

        // On-device Qwen model. Selected now, but loaded into memory LAZILY — only
        // when the first sentence actually needs translating (files are fetched to
        // disk at meeting Start). Never loaded at app launch / while idle.
        translation.enabled = false
        translationMethod = .mlx
        translationStatus = qwenHost.isLoaded
            ? "翻譯語言：\(srcName) → \(tgtName) · Qwen 模型翻譯（已載入）"
            : "翻譯語言：\(srcName) → \(tgtName) · Qwen 模型翻譯（首次翻譯時載入）"
    }

    /// Route one finalized sentence to the active translation backend.
    private func translateSentence(id: UUID, text: String) {
        switch translationMethod {
        case .apple:
            translation.translate(id: id, text: text)
        case .mlx:
            // Don't start new GPU generations once the meeting is stopping — a late
            // one could run while the model is being unloaded (clearCache crash) or
            // reload the whole 2.5 GB model after we just freed it.
            guard acceptingTranslations else { return }
            let target = settings.secondLanguage.modelTargetName   // exactly the selected language
            let srcName = settings.firstLanguage == "auto" ? "自動偵測" : settings.firstLanguage
            let tgtName = settings.secondLanguage.displayName
            // Snapshot the preceding sentences as context, then record this one for
            // the next translation (keeps the second caption coherent across lines).
            let context = mlxContext.recent
            mlxContext.append(text)
            let task = Task { [weak self] in
                guard let self else { return }
                // Always deregister this task, even on early return / cancellation.
                defer { self.inflightTranslations[id] = nil }
                // Load the model into memory on first use (already on disk from Start).
                guard await self.ensureQwenReady(srcName: srcName, tgtName: tgtName) else { return }
                guard !Task.isCancelled else { return }
                guard let translated = await self.mlxTranslator.translate(text, target: target, context: context) else { return }
                self.applyTranslation(id: id, chinese: translated)
            }
            inflightTranslations[id] = task
        case .none:
            break
        }
    }

    // MARK: - ASR events

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .interim(let text, let source, _):
            // Live partial of the sentence being spoken right now.
            interimText = text
            currentInterimSource = source
            // A new sentence started after a finalize → drop the stale interim
            // translation.
            if currentOverlayId != nil { interimChinese = "" }
            currentOverlayId = nil
            syncOverlay()
            scheduleInterimTranslation(text)
        case .finalized(let segment):
            let english = cleaner.cleanup(segment.text)
            guard !english.isEmpty else { return }
            // Stop live-translating; the accurate finalized translation takes over.
            interimThrottleTask?.cancel(); interimThrottleTask = nil
            currentInterimId = nil
            pendingInterimText = nil
            interimInFlight = false

            interimText = ""
            interimChinese = ""

            // Split a (possibly multi-sentence) utterance into individual
            // sentences, so captions appear one sentence at a time — not one
            // big block — in both the list and the overlay.
            let sentences = Self.splitSentences(english)
            var lastId: UUID?
            for sentence in sentences {
                let id = UUID()
                lastId = id
                lines.append(CaptionLine(id: id, english: sentence, chinese: nil,
                                         source: segment.source, timestamp: Date()))
                let seg = TranscriptSegment(
                    id: id,
                    sessionId: currentSessionId,
                    index: segmentIndex,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    source: segment.source,
                    speakerLabel: segment.speakerLabel,
                    sourceText: sentence
                )
                segmentIndex += 1
                store.append(seg)
                // Translate via the active backend (Apple or Qwen/MLX).
                translateSentence(id: id, text: sentence)
            }
            if lines.count > 500 { lines.removeFirst(lines.count - 500) }
            currentOverlayId = lastId   // marks that a sentence just finalized
            syncOverlay()
        }
    }

    /// Mirror the latest lines + interim into the floating overlay. The overlay's
    /// interim line is English-only by design (translation appears only once final).
    /// Only runs while listening, so a late translation arriving after the meeting
    /// ended can't repopulate the overlay with the previous session's captions.
    private func syncOverlay() {
        guard asrState == .listening else { return }
        overlay.model.lines = Array(lines.suffix(10))
        overlay.model.interim = interimText
        overlay.model.interimChinese = interimChinese   // live second caption in the overlay
        overlay.model.interimSource = currentInterimSource
    }

    private func applyTranslation(id: UUID, chinese: String) {
        // Live (interim) translation for the sentence still being spoken.
        if id == currentInterimId, currentOverlayId == nil {
            interimChinese = chinese
            interimInFlight = false
            syncOverlay()
            tryFireInterim()   // send the next pending interim, if any
            return
        }
        // A late interim result that arrived after the sentence finalized.
        if id == currentInterimId {
            interimInFlight = false
        }
        // Finalized line translation.
        if let i = lines.firstIndex(where: { $0.id == id }) {
            lines[i].chinese = chinese
        }
        store.updateTranslation(segmentId: id, translated: chinese)
        syncOverlay()
    }

    /// Translate the in-progress (interim) sentence so the second caption updates
    /// in real time. Throttled (≤ one per `interimTranslateInterval`) AND limited
    /// to a single request in flight, so a finalized sentence's accurate
    /// translation is never stuck behind a backlog of interim ones.
    private func scheduleInterimTranslation(_ text: String) {
        // Live interim translation is Apple-only (the model is too slow per word).
        guard translationMethod == .apple, settings.needsTranslation else { return }
        pendingInterimText = text
        tryFireInterim()
    }

    private func tryFireInterim() {
        guard !interimInFlight, currentOverlayId == nil, let text = pendingInterimText else { return }
        let elapsed = Date().timeIntervalSince(lastInterimTranslateAt)
        if elapsed >= interimTranslateInterval {
            fireInterim(text)
        } else if interimThrottleTask == nil {
            let delay = interimTranslateInterval - elapsed
            interimThrottleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.interimThrottleTask = nil
                self.tryFireInterim()
            }
        }
    }

    private func fireInterim(_ text: String) {
        pendingInterimText = nil
        interimInFlight = true
        lastInterimTranslateAt = Date()
        let id = UUID()
        currentInterimId = id
        translation.translate(id: id, text: text)
    }

    /// Split text into sentences, keeping terminal punctuation. Used so the
    /// transcript and overlay present one sentence at a time.
    static func splitSentences(_ text: String) -> [String] {
        let terminators: Set<Character> = [".", "?", "!", "。", "！", "？", "…"]
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if terminators.contains(ch) {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.isEmpty ? [text] : sentences
    }

    /// Clear all live-caption / live-translation bookkeeping.
    private func resetLiveCaptionState() {
        currentOverlayId = nil
        currentInterimId = nil
        pendingInterimText = nil
        interimThrottleTask?.cancel()
        interimThrottleTask = nil
        interimInFlight = false
        lastInterimTranslateAt = .distantPast
        interimChinese = ""
        mlxContext.reset()
    }

    // MARK: - Recognition / meeting lifecycle

    func startRecognition() async {
        guard asrState == .idle else { return }
        asrState = .loading
        statusMessage = "Loading Nemotron model (first run downloads it)…"
        do {
            // Start the Qwen download now (in parallel with the ASR model download),
            // both triggered by the "Start meeting" button.
            prefetchQwen()
            // Apply the selected first-caption language before loading the model.
            asr.currentLanguage = settings.firstLanguage
            asr.onLoadProgress = { [weak self] p in
                Task { @MainActor in self?.statusMessage = "Loading model… \(Int(p * 100))%" }
            }
            try await asr.loadModels(tier: settings.asrTier)
            try await asr.startStream()
            currentSession = store.beginSession(settings: settings)
            segmentIndex = 0
            lines.removeAll()
            summaryText = ""
            lastSummaryEN = nil
            lastSummaryZH = nil
            interimText = ""
            acceptingTranslations = true
            resetLiveCaptionState()
            overlay.model.clear()
            asrState = .listening
            statusMessage = "Listening — enable a source to start"
        } catch {
            asrState = .idle
            statusMessage = "ASR load failed: \(error)"
        }
    }

    // MARK: - Model preflight / uninstall

    /// Whether all on-disk models (ASR + Silero VAD + Qwen) are present.
    var modelsPresent: Bool {
        NemotronStreamingService.asrModelPresent
            && NemotronStreamingService.vadModelPresent
            && qwenHost.isComplete
    }

    /// At launch: if any model is missing, prompt the user to download up front
    /// (instead of stalling the first meeting). No-op once everything is cached.
    func preflightModels() {
        if !modelsPresent { showModelDownloadPrompt = true }
    }

    /// Download every model now (ASR variant, Silero VAD, Qwen), with progress.
    func downloadAllModels() async {
        guard !isDownloadingModels else { return }
        isDownloadingModels = true
        showModelDownloadPrompt = false
        statusMessage = "Downloading models…"
        prefetchQwen()
        asr.currentLanguage = settings.firstLanguage
        asr.onLoadProgress = { [weak self] p in
            Task { @MainActor in self?.statusMessage = "Downloading ASR model… \(Int(p * 100))%" }
        }
        do { try await asr.loadModels(tier: settings.asrTier) } catch {
            statusMessage = "ASR download failed: \(error)"
        }
        _ = await asr.prefetchVAD()
        await qwenPrefetchTask?.value
        isDownloadingModels = false
        statusMessage = modelsPresent ? "Models ready" : "Some models still missing"
    }

    /// Delete every downloaded model + app data, move the app to the Trash, and quit.
    func uninstall() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for dir in ["FluidAudio", "FlowTranslate"] {
            try? fm.removeItem(at: appSupport.appendingPathComponent(dir, isDirectory: true))
        }
        UserDefaults.standard.removeObject(forKey: "FlowTranslate.CaptionSettings")
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        NSApplication.shared.terminate(nil)
    }

    func endMeeting() async {
        asr.stopStream()
        asr.releaseModels()       // free ASR memory
        // Stop accepting new translations, then wait for any in-flight GPU
        // generation to finish BEFORE unloading the model — otherwise
        // `unloadQwen()` → `GPU.clearCache()` could fire mid-generation (crash).
        acceptingTranslations = false
        await drainInflightTranslations()
        unloadQwen()              // free the translation model now — summary is on-demand
        store.endSession()
        asrState = .idle
        interimText = ""
        interimChinese = ""
        resetLiveCaptionState()
        overlay.model.clear()
        if settings.autoCloseOverlayOnStop { overlayOn = false }   // opt-in (Settings)
        // Keep `lines` (the transcript) so it can be summarized / exported on demand.
        statusMessage = "已結束 Done · 可按「摘要 Summary」產生摘要"
    }

    /// Whether a finished-meeting transcript is available to summarize on demand
    /// (drives the Summary button: only after a meeting has ended, with content).
    var canSummarize: Bool {
        asrState == .idle && !isSummarizing && currentSession != nil && !lines.isEmpty
    }

    /// Manually generate the bilingual summary for the just-ended meeting. Loads the
    /// Qwen model on demand and frees it afterwards, so the heavy summary never runs
    /// (and never slows a new real-time session) unless the user asks for it.
    func generateSummary() async {
        guard canSummarize else { return }
        statusMessage = "產生摘要中… Generating summary…"
        await summarize()
        unloadQwen()              // free the shared Qwen model + MLX cache after the summary
        statusMessage = "摘要完成 Summary ready"
    }

    private func summarize() async {
        guard let session = currentSession else { return }
        isSummarizing = true
        defer { isSummarizing = false }

        var pair: (english: Summary, chinese: Summary)?
        do {
            // Make sure the at-Start disk prefetch finished so the summarizer loads
            // from cache instead of starting its own concurrent download.
            await qwenPrefetchTask?.value
            statusMessage = "產生摘要中 Generating summary (Qwen3-4B)…"
            pair = try await mlxSummarizer.summarizeBilingual(session: session, segments: store.segments) { p in
                Task { @MainActor in self.statusMessage = "Summarizing… \(Int(p * 100))%" }
            }
        } catch {
            // MLX unavailable (offline / first-run download failed / low memory):
            // fall back to the on-device extractive summary so the user still gets one.
            Self.log.error("Qwen summary failed: \(String(reflecting: error), privacy: .public)")
            modelStatus = "Qwen 摘要無法產生，改用內建摘要（Qwen summary unavailable, using built-in fallback）"
            statusMessage = "改用內建摘要 Using built-in summary…"
            pair = try? await fallbackSummarizer.summarizeBilingual(session: session, segments: store.segments, progress: nil)
        }

        guard let pair else { return }
        lastSummaryEN = pair.english
        lastSummaryZH = pair.chinese
        // Show English and Traditional Chinese as separate sections.
        summaryText = "🇬🇧 English\n" + Self.renderSummary(pair.english)
            + "\n\n🇹🇼 繁體中文\n" + Self.renderSummary(pair.chinese)
    }

    /// Render a single-language summary as a readable text block.
    private static func renderSummary(_ s: Summary) -> String {
        var text = s.overview
        if !s.keyPoints.isEmpty {
            text += "\n\n重點 Key Points:\n• " + s.keyPoints.joined(separator: "\n• ")
        }
        if !s.decisions.isEmpty {
            text += "\n\n決議／結論 Decisions:\n• " + s.decisions.joined(separator: "\n• ")
        }
        if !s.actionItems.isEmpty {
            text += "\n\n待辦／後續 Action Items:\n• " + s.actionItems.map { item -> String in
                var line = item.text
                if let o = item.owner { line += "（\(o)）" }
                if let d = item.due { line += "［\(d)］" }
                return line
            }.joined(separator: "\n• ")
        }
        if !s.qa.isEmpty {
            text += "\n\nQ&A:\n" + s.qa.map { "• Q: \($0.question)\n  A: \($0.answer)" }.joined(separator: "\n")
        }
        if !s.glossary.isEmpty {
            text += "\n\n名詞 Glossary:\n• " + s.glossary.map { "\($0.term): \($0.definition)" }.joined(separator: "\n• ")
        }
        return text
    }

    // MARK: - Overlay

    func toggleOverlay() { overlayOn.toggle() }   // didSet on overlayOn shows/hides

    // MARK: - Window lifecycle

    private weak var boundWindow: NSWindow?
    private var windowCloseObserver: NSObjectProtocol?

    /// Observe the main control window's close so that closing it stops capturing and
    /// hides the overlay (the app stays running for a quick reopen). Filtered to the
    /// exact window, so closing the Settings sheet doesn't trigger it.
    func bindMainWindow(_ window: NSWindow?) {
        guard let window, boundWindow !== window else { return }
        boundWindow = window
        if let old = windowCloseObserver { NotificationCenter.default.removeObserver(old) }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWindowClosed() }
        }
    }

    /// Closing the control window stops the meeting and hides the floating overlay, so
    /// the app never keeps capturing audio (or floating captions) with no visible UI.
    private func handleWindowClosed() {
        overlayOn = false                              // didSet → overlay.hide()
        if asrState == .listening { Task { await endMeeting() } }
    }

    /// Reset all overlay-related preferences to defaults (font, opacity, line count,
    /// primary line, interim style, click-through, auto-close, position) — the overlay's ↺.
    /// One assignment → one `applySettings`, and a nil position re-centres it.
    func resetOverlaySettings() {
        var s = settings
        let d = CaptionSettings.default
        s.overlayFontSize = d.overlayFontSize
        s.overlayOpacity = d.overlayOpacity
        s.historyLineCount = d.historyLineCount
        s.primaryLineOnTop = d.primaryLineOnTop
        s.interimStyle = d.interimStyle
        s.clickThrough = d.clickThrough
        s.autoCloseOverlayOnStop = d.autoCloseOverlayOnStop
        s.overlayPosition = nil
        settings = s
    }

    // MARK: - Export

    func exportTranscript() {
        guard let session = currentSession else { return }
        let exporter = TranscriptExporter()
        guard let data = try? exporter.exportBilingual(
            session: session, segments: store.segments,
            chinese: lastSummaryZH, english: lastSummaryEN, format: .markdown
        ) else {
            statusMessage = "Nothing to export"
            return
        }

        // Let the user choose where to save (NSSavePanel), defaulting to a
        // timestamped Markdown file.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FlowTranslate-\(Int(Date().timeIntervalSince1970)).md"
        panel.canCreateDirectories = true
        panel.title = "匯出逐字稿 Export transcript"
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md]
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                self?.statusMessage = "Exported transcript to \(url.path)"
            } catch {
                self?.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Audio sources

    func toggleMic() async {
        if micEnabled {
            router.disable(.microphone); micEnabled = false; micLevel = 0
            return
        }
        // If permission was previously denied, requestAccess won't prompt again —
        // guide the user to System Settings instead.
        switch Permissions.microphoneStatus {
        case .denied, .restricted:
            statusMessage = "麥克風權限被拒。請到系統設定 > 隱私權與安全性 > 麥克風 開啟 Flow Translate"
            Permissions.openMicrophoneSettings()
            return
        default:
            break
        }
        guard await Permissions.requestMicrophone() else {
            statusMessage = "麥克風權限被拒"; Permissions.openMicrophoneSettings(); return
        }
        do {
            try await router.enable(.microphone); micEnabled = true
            statusMessage = "麥克風已開啟"
        } catch {
            statusMessage = "麥克風啟動失敗: \(error.localizedDescription)"
        }
    }

    func toggleSystem() async {
        if systemEnabled {
            router.disable(.system); systemEnabled = false; systemSourceOn = false; systemLevel = 0
        } else {
            guard await Permissions.requestScreenRecording() else {
                statusMessage = "Screen Recording permission needed (System Settings > Privacy)"; return
            }
            do { try await router.enable(.system); systemEnabled = true; systemSourceOn = true }
            catch { statusMessage = "Failed to start system audio: \(error)" }
        }
    }

    private func updateLevel(_ source: AudioSourceType, _ rms: Float) {
        switch source {
        case .microphone: micLevel = rms
        case .system: systemLevel = rms
        }
    }

    // MARK: - Session bookkeeping

    private var currentSession: Session?
    private var currentSessionId: UUID { currentSession?.id ?? UUID() }
}
