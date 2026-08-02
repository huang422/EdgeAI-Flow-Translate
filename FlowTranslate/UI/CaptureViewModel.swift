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

    /// True when launch found a crashed (never-ended) session on disk — the UI
    /// offers to recover it for export/summary, or discard it (FR-008).
    @Published var showRecoveryPrompt = false
    /// Number of transcript sentences in the recoverable session (for the prompt).
    @Published private(set) var recoverableCount = 0

    enum TranslationMethod { case none, apple, mlx }
    private var translationMethod: TranslationMethod = .apple
    /// Single shared Qwen model, reused by live translation and the post-meeting
    /// summary — loaded into memory at most once.
    private let qwenHost = QwenModelHost()
    private lazy var mlxTranslator = MLXTranslator(host: qwenHost)
    /// Rolling bilingual context (source→translation pairs) for the on-device Qwen
    /// translator so the second caption stays coherent across lines (pronouns,
    /// recurring terms translated the same way). Reset at the start of each
    /// session and when the language pair changes. Capacity covers the maximum
    /// in-flight depth (1 running + 3 queued) so waiting sentences keep their
    /// preceding pairs; the prompt itself only uses the last two entries.
    private let mlxContext = BilingualContextBuffer(capacity: 5)

    // In-flight on-device (Qwen/MLX) translations, keyed by sentence id. Tracked so
    // `endMeeting()` can wait for any running GPU generation to finish BEFORE the
    // shared Qwen model is unloaded — otherwise `MLXMemory.reclaim()` would call
    // `GPU.clearCache()` mid-generation (a documented crash hazard). `accepting-
    // Translations` gates new ones so none can start once the meeting is stopping.
    private var inflightTranslations: [UUID: Task<Void, Never>] = [:]
    private var acceptingTranslations = true

    // Bounded Qwen translation queue: the model generates ONE sentence at a time,
    // so during fast speech sentences would otherwise pile up and the second
    // caption would drift ever further behind the audio. At most one sentence runs
    // on the GPU and up to `mlxQueueLimit` wait; beyond that the OLDEST waiting
    // sentence is dropped (its line simply keeps the source text — that caption
    // has usually scrolled away anyway). Freshness beats completeness here.
    private struct PendingMLXSentence { let id: UUID; let text: String }
    private var mlxQueue: [PendingMLXSentence] = []
    private var mlxRunning = false
    private let mlxQueueLimit = 3

    // Echo suppression: when system audio is playing through speakers, the mic
    // mostly hears that same audio → skip mic input to avoid garbled double
    // captions. (Accessed from the audio threads, so lock-protected — including
    // `systemSourceOn`, which the UI thread toggles.)
    private let echoLock = NSLock()
    private var lastSystemVoiceAt = Date.distantPast
    private var systemSourceOn = false

    // Level-meter throttle: post to the MainActor at most ~12 Hz per source
    // instead of once per audio chunk (dozens/sec × 2 sources of UI churn).
    private let levelLock = NSLock()
    private var lastLevelPost: [AudioSourceType: Date] = [:]

    // Serializes translation-backend resolution (avoids overlapping availability
    // checks when settings change rapidly).
    private var availabilityTask: Task<Void, Never>?
    // Lazy Qwen memory-load: started by the first sentence that needs the model
    // (during a meeting), never at app launch. Shared so concurrent sentences
    // load it once. The files are pre-downloaded to disk at meeting Start.
    private var qwenLoadTask: Task<Void, Never>?
    // Consecutive Qwen memory-load failures. A failed load no longer poisons the
    // whole meeting: the task handle is cleared so the NEXT sentence retries,
    // up to `qwenLoadFailureLimit` attempts before translation is disabled.
    private var qwenLoadFailures = 0
    private let qwenLoadFailureLimit = 2
    // Background download-to-disk of the Qwen model, kicked off at meeting Start
    // (like the ASR model) so there's no surprise download mid-meeting.
    private var qwenPrefetchTask: Task<Void, Never>?

    // Number of ASR model memory-loads currently in flight (warm preload and/or
    // a second source's pipeline). Drives the honest `.warming` state so the UI
    // never claims "Listening" while the model is still loading (audio IS
    // buffered during the load, so the user can safely start speaking).
    private var modelLoadsInFlight = 0

    // Download percentages surfaced during the Start sequence, composed into ONE
    // status line ("準備模型：ASR 42% · Qwen 背景下載 12%") instead of two
    // independently animating footer rows.
    private var asrDownloadPct: Int?
    private var qwenDownloadPct: Int?

    /// Free the Qwen model from **memory** and reset its load state. The disk
    /// prefetch is intentionally left running — the summary needs those files even
    /// after translation switches to Apple or the meeting ends. Waiting queued
    /// sentences are dropped (they belonged to the previous backend/session).
    private func unloadQwen() {
        mlxQueue.removeAll()
        qwenHost.unload()         // frees the container + returns the MLX cache to the OS
        qwenLoadTask?.cancel(); qwenLoadTask = nil
    }

    /// Cancel and await every in-flight on-device translation so no GPU generation
    /// is still running when the Qwen model is unloaded and its MLX cache cleared.
    private func drainInflightTranslations() async {
        mlxQueue.removeAll()
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
                        self.qwenDownloadPct = Int(p * 100)
                        if self.asrState == .loading {
                            // During Start, fold into the single composed line.
                            self.composeLoadingStatus()
                        } else {
                            self.modelStatus = "下載 Qwen 模型（翻譯／摘要用）… \(Int(p * 100))%"
                        }
                    }
                }
                self.qwenDownloadPct = nil
                self.modelStatus = "Qwen 模型已下載（用到時載入記憶體）"
            } catch {
                Self.log.error("Qwen prefetch failed: \(String(reflecting: error), privacy: .public)")
                self.qwenDownloadPct = nil
                self.modelStatus = "Qwen 模型下載失敗：\(Self.humanizeError(error))"
            }
        }
    }

    /// Load the Qwen model into memory on demand (guarded so it loads exactly
    /// once), showing live progress. Files are normally already on disk (fetched
    /// at Start), so this is just a memory load. Returns whether the model is ready.
    ///
    /// A failed load clears the task handle so the NEXT sentence retries (a
    /// transient failure — e.g. momentary memory pressure — no longer kills
    /// translation for the whole meeting). After `qwenLoadFailureLimit`
    /// consecutive failures translation stays off with a persistent status.
    private func ensureQwenReady(srcName: String, tgtName: String) async -> Bool {
        if qwenHost.isLoaded { return true }
        guard qwenLoadFailures < qwenLoadFailureLimit else { return false }
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
                    self.qwenLoadFailures = 0
                    self.translationStatus = "翻譯語言：\(srcName) → \(tgtName) · Qwen 模型翻譯（已載入）"
                } catch {
                    Self.log.error("Qwen load failed: \(String(reflecting: error), privacy: .public)")
                    self.qwenLoadFailures += 1
                    // Clear the handle so the next sentence can retry the load.
                    self.qwenLoadTask = nil
                    self.translationStatus = self.qwenLoadFailures >= self.qwenLoadFailureLimit
                        ? "翻譯語言：Qwen 載入失敗，本場翻譯已停用（第一字幕不受影響）"
                        : "翻譯語言：Qwen 載入失敗，下一句自動重試"
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
        case idle, loading, warming, listening

        /// Map to the overlay's status so the idle pill reflects reality instead of
        /// always claiming "Listening".
        var overlayListenState: OverlayListenState {
            switch self {
            case .idle:      return .idle
            case .loading:   return .loading
            case .warming:   return .warming
            case .listening: return .listening
            }
        }

        /// Whether a meeting is in progress (audio is being captured/buffered).
        /// `.warming` counts: the model is still loading into memory but incoming
        /// audio is already buffered and replayed, so events must be accepted.
        var isMeetingActive: Bool { self == .listening || self == .warming }
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

    // Per-source interim state: both pipelines produce partials, but only ONE
    // owns the display (arbiter with 1 s hysteresis) — two sources overwriting a
    // single interim line was a major caption-flicker source in meetings.
    private var interimBySource: [AudioSourceType: String] = [:]
    /// Stable id per in-progress utterance: minted at the first partial and
    /// REUSED as the last sentence's transcript id on finalize, so the overlay
    /// slot morphs in place (same identity) instead of jumping.
    private var utteranceIds: [AudioSourceType: UUID] = [:]
    private var interimArbiter = InterimSourceArbiter(holdInterval: 1.0)
    /// Display-side stabilizer for the overlay's live translation (prefix-freeze:
    /// only ever extends, never rewrites the head; resyncs after 3 conflicts).
    private var interimZhStable = PrefixStableText()

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
            // Update the level meter, throttled per source (independent of recognition).
            let shouldPostLevel = self.levelLock.withLock {
                let now = Date()
                guard now.timeIntervalSince(self.lastLevelPost[chunk.source] ?? .distantPast) >= 0.08
                else { return false }
                self.lastLevelPost[chunk.source] = now
                return true
            }
            if shouldPostLevel {
                Task { @MainActor in self.updateLevel(chunk.source, rms) }
            }

            let voiced = rms >= 0.012
            if chunk.source == .system {
                if voiced { self.echoLock.withLock { self.lastSystemVoiceAt = Date() } }
                self.asr.feed(chunk)
            } else {
                // Microphone: while system audio is actively playing, what the mic
                // hears is mostly the speakers (echo) → drop it so the same content
                // isn't transcribed twice / garbled. Use the system track instead.
                // Both flags read under the lock (`systemSourceOn` is written by
                // the UI thread in toggleSystem).
                let suppress = self.echoLock.withLock {
                    self.systemSourceOn
                        && Date().timeIntervalSince(self.lastSystemVoiceAt) < 0.8
                }
                if suppress { return }
                self.asr.feed(chunk)
            }
        }
        asr.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        asr.onModelLoading = { [weak self] loading in
            Task { @MainActor in
                guard let self else { return }
                // Count in-flight loads (warm preload + per-source pipelines) and
                // derive the honest warming/listening state from the total, so the
                // indicator can never be lost to a start-up scheduling race.
                self.modelLoadsInFlight = max(0, self.modelLoadsInFlight + (loading ? 1 : -1))
                self.refreshWarmingState()
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

    /// "<language>|<tier>" the ASR-variant presence hint was last checked for,
    /// so the check runs once per change instead of on every settings tick.
    private var lastVariantKey = ""
    /// Translation-relevant settings snapshot: the (async) backend-availability
    /// resolution only re-runs when one of THESE fields changes — an overlay
    /// font/opacity slider tick used to cancel + relaunch it on every step.
    private var lastTranslationKey = ""

    private func applySettings() {
        translation.enabled = settings.needsTranslation
        // "auto" first-caption → let the translator auto-detect the source.
        translation.sourceLanguage = settings.firstLanguage == "auto"
            ? "" : String(settings.firstLanguage.prefix(2))
        translation.targetLanguage = settings.secondLanguage.rawValue
        // Push the live input-gain config so a quiet source is boosted before ASR.
        router.setGain(
            system: GainConfig(
                manualGainDb: settings.systemInputGainDb,
                autoEnabled: settings.autoGainEnabled),
            mic: GainConfig(
                manualGainDb: settings.micInputGainDb,
                autoEnabled: settings.autoGainEnabled))
        overlay.applySettings(settings)
        SettingsStore.save(settings)
        let translationKey = [
            settings.firstLanguage, settings.secondLanguage.rawValue,
            String(settings.secondCaptionEnabled), settings.translationEngine.rawValue
        ].joined(separator: "|")
        if translationKey != lastTranslationKey {
            lastTranslationKey = translationKey
            availabilityTask?.cancel()
            availabilityTask = Task { await updateTranslationAvailability() }
        }
        warnIfSelectedVariantMissing()
    }

    /// After the first-caption language or ASR tier changes, tell the user right
    /// away when the newly selected variant isn't on disk (the next Start would
    /// otherwise hit a surprise ~600 MB download with no forewarning).
    private func warnIfSelectedVariantMissing() {
        let key = "\(settings.firstLanguage)|\(settings.asrTier)"
        guard key != lastVariantKey else { return }
        let isFirstCheck = lastVariantKey.isEmpty
        lastVariantKey = key
        // Launch-time presence is handled by `preflightModels()`; only warn on
        // an actual change made from Settings while idle.
        guard !isFirstCheck, asrState == .idle,
              !NemotronStreamingService.variantPresent(
                  language: settings.firstLanguage, tier: settings.asrTier)
        else { return }
        modelStatus = "所選辨識語言的模型尚未下載（約 600 MB）— 下次「開始」會自動下載，或關閉設定後於提示中先下載"
        showModelDownloadPrompt = true
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
        // and pops up a system "choose a language" sheet, so auto ALWAYS uses the
        // on-device Qwen model (regardless of the engine setting). For a specific
        // language the engine setting decides: `.qwen` forces the Qwen model;
        // `.system` uses Apple when it supports the pair (covers most languages
        // on macOS 26), else falls back to Qwen.
        let srcName: String
        let useQwen: Bool
        if settings.firstLanguage == "auto" {
            srcName = "自動偵測"
            useQwen = true
        } else if settings.translationEngine == .qwen {
            srcName = settings.firstLanguage
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
        let engineNote = settings.translationEngine == .qwen && settings.firstLanguage != "auto"
            ? "（手動指定）" : ""
        translationStatus = qwenHost.isLoaded
            ? "翻譯語言：\(srcName) → \(tgtName) · Qwen 模型翻譯\(engineNote)（已載入）"
            : "翻譯語言：\(srcName) → \(tgtName) · Qwen 模型翻譯\(engineNote)（首次翻譯時載入）"
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
            // Common short utterances ("Okay.", "Can you hear me?") are answered
            // instantly from a lookup table — 0 ms, no GPU, no queue slot — and
            // still recorded as context for the following sentences.
            if let instant = InstantPhraseTranslations.lookup(text, target: settings.secondLanguage) {
                mlxContext.append(id: id, source: text)
                applyTranslation(id: id, chinese: instant)
                return
            }
            // Record the sentence for future context, enqueue it, and bound the
            // queue by dropping the oldest waiting sentence (freshness first).
            mlxContext.append(id: id, source: text)
            mlxQueue.append(PendingMLXSentence(id: id, text: text))
            if mlxQueue.count > mlxQueueLimit {
                mlxQueue.removeFirst(mlxQueue.count - mlxQueueLimit)
            }
            pumpMLXQueue()
        case .none:
            break
        }
    }

    /// Start the next queued Qwen translation if the GPU is free. Exactly one
    /// generation runs at a time; each completion pumps the next, so the queue
    /// drains in order and `drainInflightTranslations()` only ever has to await
    /// a single running task.
    private func pumpMLXQueue() {
        guard !mlxRunning, acceptingTranslations, translationMethod == .mlx,
              !mlxQueue.isEmpty else { return }
        let next = mlxQueue.removeFirst()
        mlxRunning = true
        let target = settings.secondLanguage                   // the selected language
        let srcName = settings.firstLanguage == "auto" ? "自動偵測" : settings.firstLanguage
        let tgtName = settings.secondLanguage.displayName
        // Context = the sentences BEFORE this one (with any translations that have
        // already come back). Taken at dequeue time so it's as complete as possible.
        let recent = mlxContext.recent
        let context: [BilingualContextBuffer.Entry]
        if let idx = recent.firstIndex(where: { $0.id == next.id }) {
            context = Array(recent[..<idx])
        } else {
            context = []   // evicted from the buffer while waiting (rare)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            // Always deregister and pump the next sentence, even on early return.
            defer {
                self.inflightTranslations[next.id] = nil
                self.mlxRunning = false
                self.pumpMLXQueue()
            }
            // Load the model into memory on first use (already on disk from Start).
            guard await self.ensureQwenReady(srcName: srcName, tgtName: tgtName) else { return }
            guard !Task.isCancelled else { return }
            guard let translated = await self.mlxTranslator.translate(
                next.text, target: target, context: context) else { return }
            self.applyTranslation(id: next.id, chinese: translated)
        }
        inflightTranslations[next.id] = task
    }

    // MARK: - ASR events

    private func handle(_ event: TranscriptEvent) {
        // Drop events that arrive after the meeting ended (the pipeline's trailing
        // finalize can land late) so they can't repopulate the UI or write into an
        // already-ended session. `.warming` still accepts: buffered audio replays
        // while the model finishes loading.
        guard asrState.isMeetingActive else { return }
        switch event {
        case .interim(let text, let source, _):
            handleInterim(text: text, source: source)
        case .finalized(let segment):
            handleFinalized(segment)
        }
    }

    /// Live partial. Both sources record their partial; only the arbiter's owner
    /// drives the displayed interim (main window + overlay slot).
    private func handleInterim(text: String, source: AudioSourceType) {
        let now = Date().timeIntervalSinceReferenceDate
        interimBySource[source] = text
        let isNewUtterance = utteranceIds[source] == nil
        if isNewUtterance { utteranceIds[source] = UUID() }

        let owner = interimArbiter.interim(from: source, at: now)
        guard owner == source else { return }   // background source: recorded only

        if isNewUtterance || currentInterimSource != source {
            // New utterance (or the display switched source) → cancel the old
            // sentence's in-flight live translation entirely. A late result
            // keyed to the previous `currentInterimId` must not pass the gate
            // and land (via the NEW utterance id) on the new overlay slot.
            resetInterimTranslationPipeline()
        }
        interimText = text
        currentInterimSource = source
        // A new sentence started after a finalize → drop the stale interim
        // translation.
        if currentOverlayId != nil { interimChinese = "" }
        currentOverlayId = nil

        if let uid = utteranceIds[source] {
            overlay.model.applyInterim(
                utteranceId: uid, source: source, english: text,
                chinese: interimZhStable.displayed.isEmpty ? nil : interimZhStable.displayed,
                expectsTranslation: settings.needsTranslation)
        }
        scheduleInterimTranslation(text)
    }

    /// Finalized utterance: clean, split, persist, translate — and commit to the
    /// caption band. The LAST sentence reuses the utterance id minted at the first
    /// partial, so the overlay slot morphs in place (interim → final) instead of
    /// disappearing and re-appearing (the perceived "re-recognition" jump).
    private func handleFinalized(_ segment: ASRSegment) {
        let now = Date().timeIntervalSinceReferenceDate
        let source = segment.source
        let uttId = utteranceIds[source]
        utteranceIds[source] = nil
        interimBySource[source] = nil
        let wasDisplayed = interimArbiter.current == source
        let nextOwner = interimArbiter.end(source, at: now)

        // No active session (extreme timing edge) → nothing to attribute the
        // segment to; never invent a random session id (FR-008 integrity).
        guard let session = currentSession else { return }
        let english = cleaner.cleanup(segment.text)
        guard !english.isEmpty else {
            // Nothing usable (pure filler). Clear the displayed interim AND the
            // band slot — otherwise a dimmed caret line would linger forever.
            if wasDisplayed { clearDisplayedInterim() }
            if let uttId { overlay.model.applyDiscard(utteranceId: uttId) }
            promoteNextInterim(nextOwner)
            return
        }

        if wasDisplayed {
            // Stop live-translating; the accurate finalized translation takes over.
            clearDisplayedInterim()
        }

        // Split a (possibly multi-sentence) utterance into individual sentences,
        // so captions appear one sentence at a time — not one big block.
        let sentences = Self.splitSentences(english)
        var pairs: [(key: UUID, english: String)] = []
        for (i, sentence) in sentences.enumerated() {
            let isLast = i == sentences.count - 1
            let id = (isLast && wasDisplayed && uttId != nil) ? uttId! : UUID()
            pairs.append((key: id, english: sentence))
            lines.append(CaptionLine(id: id, english: sentence, chinese: nil,
                                     source: source, timestamp: Date()))
            let seg = TranscriptSegment(
                id: id,
                sessionId: session.id,
                index: segmentIndex,
                startTime: segment.startTime,
                endTime: segment.endTime,
                source: source,
                speakerLabel: segment.speakerLabel,
                sourceText: sentence
            )
            segmentIndex += 1
            store.append(seg)
            // Translate via the active backend (Apple or Qwen/MLX).
            translateSentence(id: id, text: sentence)
        }
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        currentOverlayId = pairs.last?.key   // marks that a sentence just finalized

        overlay.model.applyCommit(
            utteranceId: wasDisplayed ? uttId : nil,
            source: source,
            sentences: pairs,
            expectsTranslation: settings.needsTranslation)

        promoteNextInterim(nextOwner)
    }

    /// Clear the displayed interim line (main window) and its translation state.
    private func clearDisplayedInterim() {
        resetInterimTranslationPipeline()
        interimText = ""
    }

    /// After the displayed source's utterance ended, hand the interim line to the
    /// other source if it has been talking (its partials were recorded but not
    /// displayed) — so its sentence-in-progress appears instead of a blank line.
    private func promoteNextInterim(_ owner: AudioSourceType?) {
        // A BACKGROUND source finalizing returns the unchanged current owner —
        // that is "keep going", not a hand-over: never reset the live pipeline
        // of the sentence still being displayed.
        guard let owner, owner != currentInterimSource || interimText.isEmpty,
              let text = interimBySource[owner], !text.isEmpty else { return }
        if utteranceIds[owner] == nil { utteranceIds[owner] = UUID() }
        resetInterimTranslationPipeline()
        interimText = text
        currentInterimSource = owner
        currentOverlayId = nil
        if let uid = utteranceIds[owner] {
            overlay.model.applyInterim(
                utteranceId: uid, source: owner, english: text, chinese: nil,
                expectsTranslation: settings.needsTranslation)
        }
        scheduleInterimTranslation(text)
    }

    /// Reset every piece of in-flight live-translation state for the displayed
    /// interim (throttle task, single-flight token, prefix-freeze). Used when a
    /// NEW sentence takes over the display — a late result from the previous
    /// sentence must not leak into the new slot.
    private func resetInterimTranslationPipeline() {
        interimThrottleTask?.cancel(); interimThrottleTask = nil
        currentInterimId = nil
        pendingInterimText = nil
        interimInFlight = false
        interimZhStable.reset()
        interimChinese = ""
    }

    // (The old full-mirror `syncOverlay()` is gone: the overlay is now driven by
    // discrete band events — applyInterim / applyCommit / applyTranslation — so
    // SwiftUI diffs one line instead of re-evaluating the whole caption stack.)

    private func applyTranslation(id: UUID, chinese: String) {
        // Live (interim) translation for the sentence still being spoken.
        if id == currentInterimId, currentOverlayId == nil {
            // Main window shows the raw live translation (scrolling transcript
            // context tolerates rewrites)…
            interimChinese = chinese
            interimInFlight = false
            // …but the floating overlay gets the prefix-STABLE text: it only ever
            // extends, so the second caption never rewrites its head mid-sentence.
            let stable = interimZhStable.update(candidate: chinese)
            if !stable.isEmpty, let uid = utteranceIds[currentInterimSource] {
                overlay.model.applyInterimTranslation(utteranceId: uid, text: stable)
            }
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
        // Back-fill the bilingual context so the NEXT Qwen translation sees this
        // source→translation pair (no-op for Apple-translated / evicted lines).
        mlxContext.setTranslation(chinese, for: id)
        store.updateTranslation(segmentId: id, translated: chinese)
        // The band routes by translation key (slot or history; no-op if evicted).
        if asrState.isMeetingActive || overlay.model.band.hasContent {
            overlay.model.applyTranslation(key: id, text: chinese)
        }
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
        interimBySource = [:]
        utteranceIds = [:]
        interimArbiter.reset()
        interimZhStable.reset()
        mlxContext.reset()
        mlxQueue.removeAll()
    }

    // MARK: - Recognition / meeting lifecycle

    /// Status line for the honest model-warming phase. Incoming audio is ring-
    /// buffered during the load, so the user can start speaking right away.
    private static let warmingMessage = "模型載入中…可先開始說話（開頭語音不會漏）"
    private static let listeningMessage = "辨識中 Listening"

    /// Derive `.warming` ↔ `.listening` from the number of in-flight ASR model
    /// loads. Runs on every load start/finish; only meaningful mid-meeting.
    ///
    /// Known benign edge: a cancelled previous-meeting load can deliver its
    /// deferred `(false)` after a rapid Stop→Start, briefly flipping to
    /// `.listening` early — the next chunk's pipeline load flips it back, and
    /// audio is ring-buffered throughout, so no words are ever lost.
    private func refreshWarmingState() {
        switch asrState {
        case .warming:
            if modelLoadsInFlight == 0 {
                asrState = .listening
                statusMessage = Self.listeningMessage
            }
        case .listening:
            if modelLoadsInFlight > 0 {
                // A later load (e.g. the second audio source's pipeline) — show
                // the honest warming state again; its audio is buffered meanwhile.
                asrState = .warming
                statusMessage = Self.warmingMessage
            }
        case .idle, .loading:
            break
        }
    }

    /// One composed status line for the Start sequence (ASR download/verify plus
    /// the background Qwen fetch), so the footer doesn't animate two rows at once.
    private func composeLoadingStatus() {
        guard asrState == .loading else { return }
        var parts: [String] = []
        if let a = asrDownloadPct { parts.append("ASR \(a)%") }
        if let q = qwenDownloadPct, q < 100 { parts.append("Qwen 背景下載 \(q)%") }
        statusMessage = parts.isEmpty ? "準備模型… Preparing models"
                                      : "準備模型：" + parts.joined(separator: " · ")
    }

    /// Short, actionable description of a model-load/download error (instead of
    /// dumping a raw Swift error at the user).
    static func humanizeError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "無法連上網路（模型需要下載）"
            case NSURLErrorTimedOut:
                return "連線逾時"
            default:
                return "網路錯誤（\(ns.code)）"
            }
        }
        if error is ASRServiceError { return "模型檔案不完整，將於下次開始時重新下載" }
        return ns.localizedDescription
    }

    func startRecognition() async {
        // Idle only — and never while a summary is running (its unloadQwen would
        // race a new meeting's translations: documented GPU.clearCache hazard) or
        // while the launch-time bulk download runs (two concurrent downloads of
        // the same ASR variant would corrupt the cache).
        guard asrState == .idle, !isSummarizing, !isDownloadingModels else { return }
        asrState = .loading
        asrDownloadPct = nil
        composeLoadingStatus()
        // Fail fast when the selected variant needs downloading but we're offline
        // (a clear message instead of a 60 s+ URLSession hang at "0%").
        if !NemotronStreamingService.variantPresent(
            language: settings.firstLanguage, tier: settings.asrTier) {
            guard await NetworkCheck.isOnline() else {
                asrState = .idle
                statusMessage = "目前離線，且所選語言的辨識模型尚未下載（約 600 MB）。請連上網路後再按「開始」。"
                return
            }
        }
        do {
            // Start the Qwen download now (in parallel with the ASR model download),
            // both triggered by the "Start meeting" button.
            prefetchQwen()
            // Apply the selected first-caption language and scenario (video vs.
            // meeting segmentation timing) before loading the model.
            asr.currentLanguage = settings.firstLanguage
            asr.scenario = settings.scenario
            asr.onLoadProgress = { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    self.asrDownloadPct = Int(p * 100)
                    self.composeLoadingStatus()
                }
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
            qwenLoadFailures = 0
            asrDownloadPct = nil
            resetLiveCaptionState()
            overlay.model.clear()
            // Honest state: the files are on disk but the model memory-load runs
            // in the background (startStream kicked it off). Show "warming" until
            // it's resident; `refreshWarmingState` flips to listening when the
            // pending load completes. If the model is already resident (isWarm)
            // and nothing is loading, go straight to listening.
            if asr.isWarm && modelLoadsInFlight == 0 {
                asrState = .listening
                statusMessage = Self.listeningMessage
            } else {
                asrState = .warming
                statusMessage = Self.warmingMessage
            }
        } catch {
            asrState = .idle
            asrDownloadPct = nil
            statusMessage = "模型載入失敗：\(Self.humanizeError(error))。再按一次「開始」即可重試。"
        }
    }

    // MARK: - Model preflight / uninstall

    /// Whether all on-disk models (ASR + Silero VAD + Qwen) are present — for the
    /// **currently selected** first language + tier, not just any cached variant
    /// (switching language/tier can require a fresh ~600 MB variant download).
    var modelsPresent: Bool {
        NemotronStreamingService.variantPresent(
            language: settings.firstLanguage, tier: settings.asrTier)
            && NemotronStreamingService.vadModelPresent
            && qwenHost.isComplete
    }

    /// At launch: if any model is missing, prompt the user to download up front
    /// (instead of stalling the first meeting). No-op once everything is cached.
    /// While the crash-recovery prompt is up, defer — presenting two alerts on
    /// the same view at once drops one of them; the recovery actions re-invoke
    /// this when they finish.
    func preflightModels() {
        guard !showRecoveryPrompt else { return }
        if !modelsPresent { showModelDownloadPrompt = true }
    }

    // MARK: - Crash recovery (FR-008)

    /// At launch: a persisted session that was never ended means the app died
    /// mid-meeting. Offer recovery instead of silently keeping (or, worse,
    /// overwriting) the data. Guarded to THIS launch's pre-meeting state: a
    /// second window's `.task` (⌘N) re-runs this mid-meeting, and the live
    /// session must never be mistaken for a crashed one.
    func checkForRecoverableSession() {
        guard asrState == .idle, currentSession == nil,
              let fileStore = store as? FileTranscriptStore,
              let recovered = fileStore.recoverIncompleteSession(),
              !recovered.segments.isEmpty else { return }
        recoverableCount = recovered.segments.count
        showRecoveryPrompt = true
    }

    /// Load the crashed session's transcript into the UI (export + summary work
    /// as after a normal meeting) and close the session durably.
    func recoverIncompleteSession() {
        showRecoveryPrompt = false
        defer { preflightModels() }   // deferred launch prompt (see preflightModels)
        guard asrState == .idle, currentSession == nil,
              let fileStore = store as? FileTranscriptStore,
              let recovered = fileStore.recoverIncompleteSession() else { return }
        currentSession = recovered.session
        segmentIndex = (recovered.segments.map(\.index).max() ?? -1) + 1
        lines = recovered.segments.map { seg in
            CaptionLine(
                id: seg.id,
                english: seg.sourceText,
                chinese: seg.translatedText,
                source: seg.source,
                timestamp: recovered.session.startedAt.addingTimeInterval(seg.startTime))
        }
        summaryText = ""
        lastSummaryEN = nil
        lastSummaryZH = nil
        fileStore.endSession()   // close + flush → no longer flagged incomplete
        statusMessage = "已恢復上次未結束的會議（\(recovered.segments.count) 句）· 可「匯出」或產生「摘要」"
    }

    /// Throw the crashed session away (the user decided it isn't needed).
    /// Same guards as recovery: never `clear()` the store mid-meeting — that
    /// would nil the live session and silently stop all persistence.
    func discardIncompleteSession() {
        showRecoveryPrompt = false
        defer { preflightModels() }
        guard asrState == .idle, currentSession == nil else { return }
        (store as? FileTranscriptStore)?.clear()
        statusMessage = "已捨棄上次未結束的逐字稿"
    }

    // MARK: - Termination

    /// Called from `applicationShouldTerminate` (Cmd+Q, logout, shutdown): make
    /// the transcript durable before the process dies. Synchronous and fast — the
    /// debounced store write could otherwise lose the last ~2.5 s of sentences.
    func prepareForTermination() {
        if asrState.isMeetingActive {
            asr.stopStream()
            store.endSession()   // FileTranscriptStore.endSession() flushes to disk
            asrState = .idle
        } else {
            (store as? FileTranscriptStore)?.flush()
        }
    }

    /// Download every model now (ASR variant, Silero VAD, Qwen), with progress.
    /// Idle-only: running this concurrently with a meeting's `loadModels` would
    /// double-download the same ASR variant into the same directory.
    func downloadAllModels() async {
        guard !isDownloadingModels, asrState == .idle else { return }
        guard await NetworkCheck.isOnline() else {
            statusMessage = "目前離線，無法下載模型。請連上網路後再試。"
            return
        }
        isDownloadingModels = true
        showModelDownloadPrompt = false
        statusMessage = "Downloading models…"
        prefetchQwen()
        asr.currentLanguage = settings.firstLanguage
        asr.onLoadProgress = { [weak self] p in
            Task { @MainActor in self?.statusMessage = "下載 ASR 模型… \(Int(p * 100))%" }
        }
        do { try await asr.loadModels(tier: settings.asrTier) } catch {
            statusMessage = "ASR 模型下載失敗：\(Self.humanizeError(error))"
        }
        _ = await asr.prefetchVAD()
        await qwenPrefetchTask?.value
        isDownloadingModels = false
        statusMessage = modelsPresent
            ? "模型已就緒 Models ready"
            : "部分模型仍未下載 — 請檢查網路後重試 Some models still missing"
    }

    /// Delete every downloaded model + app data, remove the app's privacy (TCC)
    /// entries so a reinstall prompts fresh instead of hitting a stale toggle,
    /// move the app to the Trash, and quit.
    func uninstall() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for dir in ["FluidAudio", "FlowTranslate"] {
            try? fm.removeItem(at: appSupport.appendingPathComponent(dir, isDirectory: true))
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        } else {
            UserDefaults.standard.removeObject(forKey: "FlowTranslate.CaptionSettings")
        }
        Permissions.resetPrivacyPermissions()
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        NSApplication.shared.terminate(nil)
    }

    /// Manually clear this app's Microphone / Screen Recording privacy entries
    /// (Settings → Maintenance). Fixes the stale-permission state after replacing
    /// the app with a new build: the Privacy toggle looks ON but capture fails
    /// until the old entry is removed. Stops active sources first, since their
    /// grants are being revoked.
    func resetPrivacyPermissions() async {
        if micEnabled { await toggleMic() }
        if systemEnabled { await toggleSystem() }
        let ok = Permissions.resetPrivacyPermissions()
        statusMessage = ok
            ? "已重設權限 Permissions reset · Relaunch the app; enabling a source will ask again"
            : "重設失敗 Reset failed · Run manually: tccutil reset Microphone / ScreenCapture"
    }

    /// True while `endMeeting` is inside its drain window, so a second Stop
    /// (button mash / window close) can't run the teardown twice.
    private var isStopping = false

    func endMeeting() async {
        guard asrState.isMeetingActive, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        statusMessage = "結束中… Stopping"
        asr.stopStream()
        // Drain window: the pipelines' trailing finalize (the sentence being
        // spoken when Stop was pressed) needs a moment to decode + hop to the
        // MainActor. Stay "active" briefly so `handle()` still accepts it — the
        // last words make it into the transcript, and anything later than this
        // window is dropped by the state guard (no ghost captions).
        try? await Task.sleep(nanoseconds: 600_000_000)
        asr.releaseModels()       // free ASR memory
        // Stop accepting new translations, then wait for any in-flight GPU
        // generation to finish BEFORE unloading the model — otherwise
        // `unloadQwen()` → `GPU.clearCache()` could fire mid-generation (crash).
        acceptingTranslations = false
        await drainInflightTranslations()
        unloadQwen()              // free the translation model now — summary is on-demand
        store.endSession()
        asrState = .idle
        modelLoadsInFlight = 0
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
        // Honest completion status: `summarize()` can fail on both backends.
        statusMessage = summaryText.isEmpty
            ? "摘要失敗 Summary failed · 請再試一次（記憶體不足或模型未下載）"
            : "摘要完成 Summary ready"
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
        if asrState.isMeetingActive { Task { await endMeeting() } }
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
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f.string(from: Date()) }()
        panel.nameFieldStringValue = "FlowTranslate-\(stamp).md"
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
            router.disable(.system); systemEnabled = false; systemLevel = 0
            echoLock.withLock { systemSourceOn = false }
        } else {
            guard await Permissions.requestScreenRecording() else {
                // Also covers a stale grant after reinstall (toggle ON but capture
                // fails) — Settings → Maintenance → Reset permissions fixes that.
                statusMessage = "需要螢幕錄製權限 Screen Recording permission needed · "
                    + "If the toggle is already ON, use 設定 Settings → Reset permissions"
                Permissions.openScreenRecordingSettings()
                return
            }
            do {
                try await router.enable(.system); systemEnabled = true
                echoLock.withLock { systemSourceOn = true }
            } catch { statusMessage = "Failed to start system audio: \(error)" }
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
}
