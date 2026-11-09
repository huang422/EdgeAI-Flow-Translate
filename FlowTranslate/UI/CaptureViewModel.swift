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
    /// Diarized speaker label ("Speaker 1"…), when speaker diarization is on.
    var speakerLabel: String?
}

/// Wires audio capture → Nemotron ASR → translation → bilingual captions /
/// transcript / summary (P1–P4 integration).
@MainActor
final class CaptureViewModel: ObservableObject {
    static let log = Logger(subsystem: "dev.flowtranslate.app", category: "model")

    // Audio sources
    @Published var micEnabled = false
    @Published var systemEnabled = false
    /// Input levels, in their own observable object.
    ///
    /// Separate because they update at 12 Hz **per source**: on the view model
    /// they invalidate every observing view ~24 times a second while a meeting
    /// runs, including the whole Settings window — one block of which renders the
    /// 52-rule markdown to show a token count.
    ///
    /// Only the two meters observe this, so a level change now repaints two small
    /// views and nothing else.
    let levels = LevelMeters()

    // Recognition / captions
    @Published var asrState: ASRState = .idle {
        didSet { overlay.model.listenState = asrState.overlayListenState }
    }
    @Published var interimText = ""
    @Published var interimChinese = ""
    @Published var lines: [CaptionLine] = []
    /// Clearing `statusAction` here rather than at every write site: this is set
    /// from dozens of places and only two of them offer a button, so a stale
    /// "開啟設定" would otherwise outlive the message that justified it and sit
    /// beside something unrelated.
    @Published var statusMessage = "Idle" {
        didSet { statusAction = nil }
    }
    /// A privacy pane offered alongside `statusMessage`, or nil. Set *after* the
    /// message it belongs to.
    @Published var statusAction: PermissionPane?

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
    /// Identifies the most recent auto-clearing message, so a later one can't be
    /// wiped by an older one's timer.
    private var modelStatusFlash = UUID()

    /// Show a status line that clears itself. A one-off success ("ready",
    /// "downloaded") that never clears sits in the footer for the rest of the
    /// meeting pretending to be current state. Problems still use `modelStatus`
    /// directly and stay put until something replaces them.
    private func flashModelStatus(_ text: String, seconds: Double = 4) {
        modelStatus = text
        let token = UUID()
        modelStatusFlash = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.modelStatusFlash == token else { return }
            self.modelStatus = ""
        }
    }

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

    /// Everything that currently owns the shared ASR service or the Qwen host,
    /// other than the prompt features themselves.
    ///
    /// `asrState != .idle` alone is **not** enough. `generateSummary()` runs at
    /// `.idle` and calls `releaseQwen()` → `unload()` → `MLXMemory.reclaim()`;
    /// a prompt compile generating at that moment is exactly the
    /// `GPU.clearCache()`-mid-generation crash the rest of this file is written
    /// to avoid. `downloadAllModels()` also runs at `.idle` and drives the same
    /// `MLXModelDownloader` a compile would.
    private var isSharedModelBusy: Bool {
        isClosingResources || asrState != .idle || isSummarizing || isDownloadingModels
    }

    /// The three prompt workloads that contend for the shared model.
    enum PromptWorkload { case composer, hotkey, eval }

    /// Names what is holding the shared models, or nil when nothing is.
    ///
    /// A bare "models are busy" reads as a stuck UI: the one thing the user needs
    /// in order to unblock themselves is *which* work to stop, and that is
    /// exactly what the message left out.
    private func sharedModelBlocker(excluding consumer: PromptWorkload) -> String? {
        if isClosingResources { return "正在釋放模型 Closing" }
        if isResettingPermissions { return "重設權限中 Resetting permissions" }
        if asrState != .idle { return "會議進行中 Meeting in progress" }
        if isSummarizing { return "產生摘要中 Generating summary" }
        if isDownloadingModels { return "下載模型中 Downloading models" }
        if consumer != .composer, isComposerLoaded, composer.isBusy {
            return "Prompt 分頁工作中 Prompt tab is working"
        }
        if consumer != .hotkey, isQuickDictationLoaded, quickDictation.isRunning {
            return "快捷鍵口述中 Hotkey dictation running"
        }
        if consumer != .eval, isPromptEvalLoaded, promptEval.isRunning {
            return "評測進行中 Eval running"
        }
        return nil
    }

    /// The Prompt tab's view model. Shares this object's ASR service and Qwen
    /// host — the feature adds no resident model memory. `lazy` because it
    /// captures `self`.
    /// Whether the composer has been built yet, so settings changes can reach it
    /// without being the thing that creates it.
    private var isComposerLoaded = false
    /// The settings as they were at the last `applySettings`, so the composer can
    /// tell what actually changed.
    private var previousSettings = CaptionSettings()

    /// The three prompt workloads are separate `ObservableObject`s, and the busy
    /// banner is derived from all three at once: the Prompt tab is blocked while
    /// the hotkey or the eval runs, and vice versa. A view observing one of them
    /// is not redrawn when another changes, so the banner appeared when a
    /// workload started and then stayed after it stopped — until an unrelated
    /// edit happened to force a redraw. Re-emitting each child's *phase* (not its
    /// text, which changes per keystroke) through this object gives every view a
    /// single thing to observe, and the banner clears the moment work ends.
    private var workloadObservers: [AnyCancellable] = []

    /// Delivery is deferred by one hop because a child's `objectWillChange` can
    /// fire while SwiftUI is evaluating a body, and sending ours synchronously
    /// from there is the "Publishing changes from within view updates" trap.
    private func republishPhase<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &workloadObservers)
    }

    lazy var composer: PromptComposerViewModel = {
        isComposerLoaded = true
        return makeComposer()
    }()

    private func makeComposer() -> PromptComposerViewModel {
        let composer = PromptComposerViewModel(
            asr: asr,
            router: router,
            qwenHost: qwenHost,
            settings: { [weak self] in self?.settings ?? CaptionSettings() },
            // Also blocked by the hotkey flow: both borrow `asr.onEvent` and open
            // a `MicCapture`, so running them together corrupts the handler chain.
            blockedBy: { [weak self] in
                guard let self else { return "已結束 Cancelled" }
                return self.sharedModelBlocker(excluding: .composer)
            },
            didFinishWork: { [weak self] in self?.schedulePromptModelRelease() },
            // `self?.method() ?? default` collapses BOTH optionals: the method
            // returns nil for success, and `??` replaced that nil with the
            // failure string — so every successful load was reported as a
            // failure. The two cases have to be separated explicitly.
            prepareModel: { [weak self] in
                guard let self else { return "已結束 Cancelled" }
                return await self.ensureQwenReadyForPrompt()
            }
        )
        republishPhase(composer.$phase)
        return composer
    }

    /// The ⌃⌥Space flow. Kept separate from `composer` so a hotkey dictation
    /// never overwrites a draft the user has open in the Prompt tab.
    lazy var quickDictation: QuickDictationController = {
        isQuickDictationLoaded = true
        let controller = makeQuickDictation()
        republishPhase(controller.$phase)
        return controller
    }()

    /// Whether `quickDictation` has ever been built, so a check that only needs
    /// to know "is one running" does not construct one to find out — the same
    /// guard `isComposerLoaded` provides. Reading the lazy value opens a
    /// `MicCapture` for a user who may never press the key.
    private var isQuickDictationLoaded = false

    private func makeQuickDictation() -> QuickDictationController { QuickDictationController(
        asr: asr,
        router: router,
        qwenHost: qwenHost,
        blockedBy: { [weak self] in
            guard let self else { return "已結束 Cancelled" }
            return self.sharedModelBlocker(excluding: .hotkey)
        },
        settings: { [weak self] in self?.settings ?? CaptionSettings() },
        rulebook: { [weak self] in self?.activePromptRulebook ?? PromptStdlib.all },
        didFinishWork: { [weak self] in
            self?.schedulePromptModelRelease()
            self?.prepareForCaptions(refresh: true)
        },
        didMoveHUD: { [weak self] origin in self?.settings.promptHUDPosition = origin },
        didChangeInsertMode: { [weak self] mode in self?.settings.promptQuickInsertMode = mode },
        prepareModel: { [weak self] in
            guard let self else { return "已結束 Cancelled" }
            return await self.ensureQwenReadyForPrompt()
        }
    ) }

    /// Grades the prompt pipeline against the real model. Shares the same host,
    /// and is mutually exclusive with everything else that uses it.
    lazy var promptEval: PromptEvalRunner = {
        isPromptEvalLoaded = true
        let runner = makePromptEval()
        republishPhase(runner.$progress)
        return runner
    }()

    /// Whether `promptEval` has ever been built.
    private var isPromptEvalLoaded = false

    /// Ask each prompt workload whether it is busy **without building it**.
    ///
    /// Every one of these objects is expensive to exist: a
    /// `PromptComposerViewModel` is a `DictationSession` plus a 52-rule
    /// `RulebookStore.load()` decode, and a `QuickDictationController` adds a
    /// second session and an `NSPanel`. They are `lazy` for that reason, so a user
    /// who never opens the Prompt tab must not pay for them — one accessor, so a
    /// future check cannot forget the guard.
    private var busyPromptWorkloads: Bool {
        (isComposerLoaded && composer.isBusy)
            || (isQuickDictationLoaded && quickDictation.isRunning)
            || (isPromptEvalLoaded && promptEval.isRunning)
    }

    /// The rulebook that will actually be installed, read without building the
    /// composer to get it.
    ///
    /// The user's edited book, never `PromptStdlib.all`, so Settings, the Prompt
    /// page and the file on disk cannot give three answers for one file. Filtered
    /// by the enabled categories: a category that is off does not exist for this
    /// project. Falls back to the store rather than the composer — the hotkey, the
    /// eval and Settings all need this, and none is a reason to build one.
    var activePromptRulebook: PromptRulebook {
        activePromptRulebookIgnoringCategories.filtered(to: settings.promptRuleCategories)
    }

    /// The same book with every category still in it — what the category picker
    /// needs in order to say how many rules each row would add.
    var activePromptRulebookIgnoringCategories: PromptRulebook {
        isComposerLoaded ? composer.rulebook : RulebookStore.load()
    }

    /// Cancel and await whatever prompt work exists. Never builds one to cancel
    /// it: an object that does not exist has nothing on the GPU.
    private func drainPromptWorkloads() async {
        if isComposerLoaded { await composer.cancelAndDrain() }
        if isQuickDictationLoaded { await quickDictation.cancelAndDrain() }
        if isPromptEvalLoaded { await promptEval.cancelAndDrain() }
    }

    private func makePromptEval() -> PromptEvalRunner { PromptEvalRunner(
        qwenHost: qwenHost,
        blockedBy: { [weak self] in
            guard let self else { return "已結束 Cancelled" }
            return self.sharedModelBlocker(excluding: .eval)
        },
        settings: { [weak self] in self?.settings ?? CaptionSettings() },
        rulebook: { [weak self] in self?.activePromptRulebook ?? PromptStdlib.all },
        didFinishWork: { [weak self] in self?.schedulePromptModelRelease() },
        prepareModel: { [weak self] in
            guard let self else { return "已結束 Cancelled" }
            return await self.ensureQwenReadyForPrompt()
        }
    ) }

    /// Debounced release of the shared Qwen model after prompt work goes idle.
    private var promptIdleReleaseTask: Task<Void, Never>?

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

    // Transcript correction (accurate track). Deliberately a SEPARATE, lower
    // priority queue from translation: a correction is never on screen, so it
    // must never make a viewer wait for a subtitle. It only starts when the
    // translation queue is idle, and its own backlog is bounded the same way —
    // beyond `correctionQueueLimit` the oldest waiting sentence is dropped and
    // keeps its raw ASR text.
    private struct PendingCorrection { let id: UUID; let text: String }
    private lazy var corrector = QwenCorrector(host: qwenHost)
    private var correctionQueue: [PendingCorrection] = []
    private var correctionRunning = false
    private var inflightCorrection: Task<Void, Never>?
    private var acceptingCorrections = false
    private let correctionQueueLimit = 4

    // Echo suppression: when system audio is playing through speakers, the mic
    // mostly hears that same audio → skip mic input to avoid garbled double
    // captions. (Accessed from the audio threads, so lock-protected — including
    // `systemSourceOn`, which the UI thread toggles.)
    private let echoLock = NSLock()
    private var lastSystemVoiceAt = Date.distantPast
    private var systemSourceOn = false
    private var micSuppressionEnabled = false

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

    // Download percentages surfaced during the Start sequence, composed into ONE
    // status line ("準備模型：ASR 42% · Qwen 背景下載 12%") instead of two
    // independently animating footer rows.
    private var asrDownloadPct: Int?
    private var qwenDownloadPct: Int?
    private var diarDownloadPct: Int?

    /// Release the shared Qwen model from **memory**. Safe from any call site.
    ///
    /// Two things must hold before the model can go:
    ///
    /// 1. **Nothing may still be generating.** `unload()` → `MLXMemory.reclaim()`
    ///    → `GPU.clearCache()` during a live generation is a documented crash.
    /// 2. **No other consumer may still need it.** Transcript correction shares
    ///    the same host, so the model stays resident while correction is live —
    ///    including mid-generation after the setting has just been switched off,
    ///    which a setting-only check would miss.
    ///
    /// The disk prefetch is deliberately left running: the summary needs those
    /// files even after translation switches to Apple or the meeting ends.
    private func releaseQwen(summaryFinished: Bool = false) async {
        guard !isSummarizing || summaryFinished else { return }
        mlxQueue.removeAll()
        // Only a consumer that will still be GIVEN work keeps the model. A
        // generation merely running right now must not block the release —
        // draining it is what the calls below are for — or 2.3 GB stays resident
        // forever whenever a meeting ends mid-repair.
        guard !(settings.transcriptCorrectionEnabled && acceptingCorrections) else { return }
        // The prompt features hold this same host, and unloading under a live
        // compile is the `GPU.clearCache` hazard above.
        let loading = qwenLoadTask
        loading?.cancel()
        await drainPromptWorkloads()
        await drainInflightTranslations()
        await drainCorrections()
        await loading?.value
        qwenHost.unload()         // frees the container + returns the MLX cache to the OS
    }

    /// Free the shared Qwen model once the prompt features have been idle for a
    /// while.
    ///
    /// Without this, a user who only ever uses the Prompt tab loads ~2.3 GB on
    /// their first compile and it stays resident until the app quits — the
    /// meeting paths were the only ones that ever released it. Debounced rather
    /// than immediate because compiling twice in a row is the normal case, and
    /// reloading between them would cost more than it saves.
    func schedulePromptModelRelease() {
        promptIdleReleaseTask?.cancel()
        promptIdleReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self else { return }
            guard self.asrState == .idle, !self.isSummarizing, !self.isDownloadingModels,
                  !self.busyPromptWorkloads
            else { return }
            await self.releaseQwen()
            self.modelStatus = ""
        }
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

    /// What the prompt features can say about the shared model right now.
    ///
    /// Two stages, and they are not the same wait: entering the tab downloads
    /// ~2.3 GB to disk, and the first compile loads it into memory. Compiling
    /// without either is possible — the compile does both — but it turns a
    /// button press into a multi-minute silence, which is why the state is
    /// surfaced rather than hidden inside the first compile.
    enum PromptModelState: Equatable {
        case downloading(Double?)
        case onDisk
        case loaded
        case unavailable(String)
    }

    var promptModelState: PromptModelState {
        if qwenHost.isLoaded { return .loaded }
        if qwenPrefetchTask != nil {
            return .downloading(qwenDownloadPct.map { Double($0) / 100 })
        }
        if !qwenHost.isComplete { return .unavailable("模型尚未下載 Model not downloaded") }
        return .onDisk
    }

    /// The `"<engine>|<language>|<tier>"` the dictation variant was last prepared
    /// for. Keyed, not latched: the variant is derived from settings the user can
    /// edit between visits to the Prompt tab, so a "done once per launch" flag
    /// leaves the new variant unfetched.
    private var prewarmedDictationKey: String?

    /// Prepare the selected dictation variant while idle. Same-variant weights
    /// are reused; changing language/tier replaces them. The service rejects a
    /// late prewarm result if a newer preparation or stream has begun.
    private func prewarmDictationASR() {
        guard !isDownloadingModels, asrState == .idle else { return }
        // **Whichever engine is selected.** The built-in recognizer's assets are
        // the system's, but the system fetches them on first use — and first use
        // is the user waiting.
        let engine = DictationEngineFactory.resolved(settings)
        let language = PromptDictation.language(for: settings, engine: engine)
        // Merely visiting Prompt must not displace the selected caption preload.
        if engine == .nemotron, asr.isWarm || captionPrewarmInProgress { return }
        let key = "\(engine.rawValue)|\(language)|\(PromptDictation.tier)"
        guard key != prewarmedDictationKey else { return }
        prewarmedDictationKey = key
        Task { [weak self] in
            guard let self else { return }
            switch engine {
            case .nemotron:
                // Fetches the variant *and* loads the weights, which then stay
                // resident: `stopStream(keepModelsResident:)` no longer frees them
                // between dictations, so this is paid once per tab visit rather
                // than once per sentence.
                await self.asr.prewarmVariant(language: language, tier: PromptDictation.tier)
            case .appleSpeech:
                if #available(macOS 26.0, *) {
                    await AppleDictationEngine.prewarm(language: language)
                }
            }
        }
    }

    func prepareForPromptWork() {
        guard !AppEnvironment.isUIFixture else { return }
        guard !isSharedModelBusy else { return }
        prewarmDictationASR()
        promptIdleReleaseTask?.cancel()
        promptIdleReleaseTask = nil
        prefetchQwen()
    }

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
                self.flashModelStatus("Qwen 模型已下載（用到時載入記憶體）")
            } catch {
                Self.log.error("Qwen prefetch failed: \(String(reflecting: error), privacy: .public)")
                self.qwenDownloadPct = nil
                self.modelStatus = "Qwen 模型下載失敗：\(Self.humanizeError(error))"
            }
        }
    }

    /// How a shared-Qwen memory load is progressing. Translation and transcript
    /// correction both wait on the same load but describe it differently (and in
    /// different status lines), so each maps these phases to its own wording.
    enum QwenLoadPhase { case loading(Double?), ready, failedRetryable, failedFinal }

    /// Load the Qwen model into memory on demand (guarded so it loads exactly
    /// once), reporting progress through `report`. Files are normally already on
    /// disk (fetched at Start), so this is just a memory load. Returns whether the
    /// model is ready.
    ///
    /// Every consumer — live translation and the transcript corrector — comes
    /// through here, so the ~2.3 GB model is loaded once regardless of which one
    /// needs it first.
    ///
    /// A failed load clears the task handle so the NEXT sentence retries (a
    /// transient failure — e.g. momentary memory pressure — no longer kills
    /// translation for the whole meeting). After `qwenLoadFailureLimit`
    /// consecutive failures the feature stays off with a persistent status.
    private func ensureQwenReady(
        report: @escaping @MainActor (QwenLoadPhase) -> Void
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if qwenHost.isLoaded { return true }
        guard qwenLoadFailures < qwenLoadFailureLimit else { return false }
        if qwenLoadTask == nil {
            qwenLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                report(.loading(nil))
                // Wait for the at-Start disk prefetch (if any) so we don't download twice.
                do {
                    if let prefetch = self.qwenPrefetchTask {
                        _ = await CancellableTaskWait.wait(for: prefetch)
                    }
                    try Task.checkCancellation()
                    try await self.qwenHost.ensureLoaded { p in
                        Task { @MainActor in report(.loading(p)) }
                    }
                    self.qwenLoadFailures = 0
                    // Clear on success too. A finished task left in the handle
                    // makes the next caller `await` something already done and
                    // then read `isLoaded` — which is false if anything unloaded
                    // the model in between, so the load is never re-attempted.
                    self.qwenLoadTask = nil
                    report(.ready)
                } catch is CancellationError {
                    self.qwenLoadTask = nil
                } catch {
                    Self.log.error("Qwen load failed: \(String(reflecting: error), privacy: .public)")
                    self.qwenLoadFailures += 1
                    // Clear the handle so the next sentence can retry the load.
                    self.qwenLoadTask = nil
                    report(self.qwenLoadFailures >= self.qwenLoadFailureLimit
                           ? .failedFinal : .failedRetryable)
                }
            }
        }
        if let loading = qwenLoadTask {
            _ = await CancellableTaskWait.wait(for: loading)
        }
        return !Task.isCancelled && qwenHost.isLoaded
    }

    /// Await the shared model for a live translation, narrating on `translationStatus`.
    private func ensureQwenReadyForTranslation(srcName: String, tgtName: String) async -> Bool {
        await ensureQwenReady { [weak self] phase in
            guard let self else { return }
            let pair = "翻譯語言：\(srcName) → \(tgtName)"
            switch phase {
            case .loading(nil):        self.translationStatus = "\(pair) · Qwen 模型載入中…"
            case .loading(let p?):     self.translationStatus = "\(pair) · Qwen 模型載入中… \(Int(p * 100))%"
            case .ready:               self.translationStatus = "\(pair) · Qwen 模型翻譯（已載入）"
            case .failedRetryable:     self.translationStatus = "翻譯語言：Qwen 載入失敗，下一句自動重試"
            case .failedFinal:         self.translationStatus = "翻譯語言：Qwen 載入失敗，本場翻譯已停用（第一字幕不受影響）"
            }
        }
    }

    /// Whether the shared model is resident **right now**. Never blocks: if it
    /// isn't, the load is kicked off in the background and this sentence is
    /// skipped. See the call site for why correction must not await the load.
    private func qwenReadyForCorrection() -> Bool {
        if qwenHost.isLoaded { return true }
        guard qwenLoadFailures < qwenLoadFailureLimit, qwenLoadTask == nil else { return false }
        Task { @MainActor [weak self] in
            guard let self, self.acceptingCorrections, !self.isClosingResources else { return }
            _ = await self.ensureQwenReadyForCorrection()
        }
        return false
    }

    /// Await the shared model for transcript correction. Reported on `modelStatus`,
    /// not `translationStatus`: correction can be on while Apple handles
    /// translation, and a translation-flavoured message would be a lie there.
    /// Load the shared model for a prompt compile, narrating on `modelStatus`.
    ///
    /// Returns `nil` on success, or a message to show when the model cannot be
    /// had. Routed through `ensureQwenReady` like every other consumer, so the
    /// prompt features inherit the consecutive-failure budget, the single shared
    /// load task, and the wait on the at-Start prefetch.
    func ensureQwenReadyForPrompt() async -> String? {
        // A user-initiated compile is a retry request. The budget exists to stop
        // a broken install being retried on every caption of a meeting — it was
        // never meant to outlive that meeting, but it was only ever reset at the
        // next Start, so two failed loads left every prompt compile reporting
        // "model unavailable" indefinitely with no way back.
        if !qwenHost.isLoaded, qwenLoadFailures >= qwenLoadFailureLimit {
            qwenLoadFailures = 0
        }
        var failure: String?
        let ready = await ensureQwenReady { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .loading(nil):    self.modelStatus = "Prompt：Qwen 模型載入中…"
            case .loading(let p?): self.modelStatus = "Prompt：Qwen 模型載入中… \(Int(p * 100))%"
            case .ready:           self.flashModelStatus("Prompt：模型已就緒")
            case .failedRetryable:
                self.modelStatus = "Prompt：模型載入失敗，可再試一次"
                failure = "模型載入失敗，可再試一次 Model load failed — try again"
            case .failedFinal:
                self.modelStatus = "Prompt：模型載入連續失敗，已停用（請檢查網路或磁碟空間）"
                failure = "模型連續載入失敗，已停止重試 Model load failed repeatedly"
            }
        }
        if ready { return nil }
        // A budget already spent reports no phase at all, so give the caller a
        // reason rather than a silent nil-success.
        return failure ?? "模型無法載入 Model unavailable"
    }

    private func ensureQwenReadyForCorrection() async -> Bool {
        await ensureQwenReady { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .loading(nil):        self.modelStatus = "AI 校正：Qwen 模型載入中…"
            case .loading(let p?):     self.modelStatus = "AI 校正：Qwen 模型載入中… \(Int(p * 100))%"
            case .ready:               self.flashModelStatus("AI 校正：已就緒（字幕不受影響）")
            case .failedRetryable:     self.modelStatus = "AI 校正：模型載入失敗，下一句自動重試"
            case .failedFinal:         self.modelStatus = "AI 校正：模型載入失敗，本場已停用（逐字稿保留原文）"
            }
        }
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
    /// Audio time of the newest partial per source.
    ///
    /// The pipeline gives a partial no utterance identity, so this view model
    /// infers the boundary from "the previous utterance has finalized". That
    /// inference is wrong whenever a finalize arrives *after* the next utterance
    /// has already started producing partials — which is the ordinary case when
    /// someone keeps talking, because the decode lags the speech. The finalize
    /// then claimed the partial that was on screen, overwrote the sentence being
    /// spoken with the previous one, and cleared its live translation.
    ///
    /// Comparing audio times settles it without needing an identity: a partial
    /// covering audio past the segment's end cannot be part of that segment.
    private var lastInterimAudioTime: [AudioSourceType: TimeInterval] = [:]
    private var interimArbiter = InterimSourceArbiter(holdInterval: 1.0)
    /// Display-side stabilizer for the overlay's live translation (prefix-freeze:
    /// only ever extends, never rewrites the head; resyncs after 3 conflicts).
    private var interimZhStable = PrefixStableText()

    /// Turns the diarizer's `Speaker 1` into `Claude Mango`.
    ///
    /// Lives here, at the point where labels are *consumed*, rather than inside
    /// either source pipeline. Mic and system audio keep separate speaker
    /// databases on purpose — the same voice on both would otherwise merge — so
    /// each pipeline numbers its speakers from 1 independently, and only this
    /// object sees both. Naming per pipeline would hand two different people the
    /// same name. The key carries the source for exactly that reason.
    private var speakerNamer = SpeakerNamer()

    /// The named form of a raw diarizer label, or nil when there is none.
    private func speakerName(for rawLabel: String?, source: AudioSourceType) -> SpeakerName? {
        guard let rawLabel, !rawLabel.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return speakerNamer.name(for: "\(source.rawValue)#\(rawLabel)")
    }

    init() {
        // Bound the MLX Metal cache up front so freed Qwen weights / KV caches are
        // returned to the OS instead of lingering (the main memory-bloat fix).
        if !AppEnvironment.isUIFixture { MLXMemory.configureAtLaunch() }

        // Persist the transcript to Application Support so an unexpected close
        // does not lose accumulated segments (FR-008).
        let dir = AppEnvironment.dataDirectory
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
                    self.micSuppressionEnabled && self.systemSourceOn
                        && Date().timeIntervalSince(self.lastSystemVoiceAt) < 0.8
                }
                if suppress { return }
                self.asr.feed(chunk)
            }
        }
        asr.onEvent = { [weak self] event in
            self?.handle(event)
        }
        asr.onModelLoading = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshWarmingState()
                if self.captionPrewarmInProgress, self.asrState == .idle,
                   let failure = self.asr.modelLoadFailure {
                    self.statusMessage = "模型預熱失敗：\(failure)。可按「開始」重試。"
                }
                if self.asr.isWarm || self.asr.modelLoadFailure != nil {
                    self.captionPrewarmInProgress = false
                }
            }
        }
        asr.onVadUnavailable = { [weak self] msg in
            Task { @MainActor in self?.statusMessage = "⚠️ " + msg }
        }
        asr.onDiarizationLoadProgress = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.diarDownloadPct = Int(p * 100)
                if self.asrState == .loading {
                    self.composeLoadingStatus()   // fold into the single Start line
                } else {
                    self.modelStatus = "下載講者辨識模型（pyannote）… \(Int(p * 100))%"
                }
                if p >= 1 { self.diarDownloadPct = nil }
            }
        }
        asr.onDiarizationUnavailable = { [weak self] msg in
            Task { @MainActor in self?.statusMessage = "⚠️ 講者辨識無法使用（字幕不受影響）: " + msg }
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
            self?.settings.overlayBottomAnchor = origin
        }
        overlay.onReset = { [weak self] in
            self?.resetOverlaySettings()
        }
        if AppEnvironment.isUIFixture {
            translationStatus = "翻譯語言：en-US → 繁體中文 · Apple 系統翻譯（即時）"
            statusMessage = "隔離 UI 測試：音訊、模型與全域快捷鍵停用。請使用 /Applications/FlowTranslate.app 操作正式功能。"
            if AppEnvironment.fixtureScenario == "summary" {
                summaryText = String(repeating: "會議摘要 Meeting summary — decisions and follow-up actions.\n", count: 20)
            }
            return
        }
        applySettings()
        registerGlobalShortcuts()
    }

    /// Global shortcuts (work even while another app like Zoom is focused).
    /// ⌃⌥C overlay · ⌃⌥= / ⌃⌥- font size · ⌃⌥P pin (spec §2.8).
    private func registerGlobalShortcuts() {
        let mod = controlKey | optionKey
        let center = GlobalHotKeyCenter.shared
        var failed: [String] = []
        func register(_ name: String, keyCode: Int, label: String, handler: @escaping () -> Void) {
            if !center.register(name, keyCode: keyCode, modifiers: mod, handler: handler) {
                failed.append(label)
            }
        }
        register("overlay.toggle", keyCode: kVK_ANSI_C, label: "⌃⌥C") { [weak self] in
            Task { @MainActor in self?.toggleOverlay() }
        }
        register("overlay.font.increase", keyCode: kVK_ANSI_Equal, label: "⌃⌥=") { [weak self] in
            Task { @MainActor in self?.stepOverlayFont(1) }
        }
        register("overlay.font.decrease", keyCode: kVK_ANSI_Minus, label: "⌃⌥−") { [weak self] in
            Task { @MainActor in self?.stepOverlayFont(-1) }
        }
        register("overlay.pin", keyCode: kVK_ANSI_P, label: "⌃⌥P") { [weak self] in
            Task { @MainActor in self?.overlay.togglePin() }
        }
        // ⌃⌥Space is registered from `applySettings`, not here: it is the one
        // shortcut with a switch, and a Carbon hot key holds the combination for
        // the whole process. Registering it unconditionally and checking the
        // setting on dispatch meant switching it off still swallowed ⌃⌥Space in
        // every other application — the switch changed nothing a user could
        // observe except that nothing happened.
        applyDictationHotkey()
        if !failed.isEmpty {
            statusMessage = "快捷鍵無法註冊：\(failed.joined(separator: ", ")) · 請關閉其他 FlowTranslate 副本或占用這些按鍵的 App，再重新啟動。"
        }
    }

    /// The name the dictation shortcut is registered under.
    private static let dictationHotkeyName = "prompt.dictation"

    /// Whether the "⌃⌥Space is taken" message has already been shown this launch,
    /// so a failing registration reports once instead of on every settings write.
    private var didReportHotkeyConflict = false

    /// Hold or release ⌃⌥Space to match the setting.
    private func applyDictationHotkey() {
        let center = GlobalHotKeyCenter.shared
        guard settings.promptHotkeyEnabled else {
            center.unregister(Self.dictationHotkeyName)
            didReportHotkeyConflict = false
            // A session running right now could no longer be finished — the key
            // that finishes it has just been handed back to the system — so it is
            // cancelled rather than left holding the microphone with no way to
            // stop it. Cancelled, not finished: inserting text at the cursor is
            // not what switching a feature off asks for.
            if isQuickDictationLoaded, quickDictation.isRunning {
                Task { [weak self] in await self?.quickDictation.cancelAndDrain() }
            }
            return
        }
        guard !center.isRegistered(Self.dictationHotkeyName) else { return }
        // Carbon hot keys only deliver key-down, so this toggles rather than
        // being push-to-talk.
        let registered = center.register(
            Self.dictationHotkeyName, keyCode: kVK_Space, modifiers: controlKey | optionKey
        ) { [weak self] in
            Task { @MainActor in self?.toggleQuickDictation() }
        }
        // Said out loud, because the failure is otherwise invisible and looks
        // exactly like a broken feature: `RegisterEventHotKey` refuses a
        // combination another process already owns, and ⌃⌥Space is a popular one.
        // The switch then reads ON while the key does nothing at all, with the
        // app's own logs the only place the refusal was recorded.
        guard !registered else {
            didReportHotkeyConflict = false
            return
        }
        guard !didReportHotkeyConflict else { return }
        didReportHotkeyConflict = true
        statusMessage = "⌃⌥Space 已被其他程式佔用，口述快捷鍵無法註冊"
            + " — ⌃⌥Space is taken by another app"
    }

    /// Turn the ⌃⌥Space hotkey on or off, asking for what it needs **on the way
    /// on**.
    ///
    /// The same shape as `toggleMic` and `toggleSystem`: the user presses the
    /// control, the control checks what it needs, and a missing permission is
    /// asked for there and then. Bound to the switch rather than reached from
    /// `applySettings`, because only a press is a moment the user is expecting to
    /// be asked — `applySettings` also runs at launch and on every unrelated
    /// settings write.
    ///
    /// Asked here rather than at the first ⌃⌥Space because that key is pressed
    /// from *another* application, with this one in the background: TCC's dialog
    /// then opens behind whatever the user is looking at, which is the same as not
    /// asking at all.
    func setDictationHotkey(_ on: Bool) {
        guard !AppEnvironment.isUIFixture else { return }
        settings.promptHotkeyEnabled = on
        guard on else { return }
        Permissions.requestAccessibilityOnce()
        if !Permissions.accessibilityAuthorized {
            statusMessage = "口述插入游標需要「輔助使用」權限 Accessibility required"
            statusAction = .accessibility
        }
    }

    /// Start or finish a hotkey dictation. Ignored while a meeting is running,
    /// for the same mutual-exclusion reason the Prompt tab's buttons are.
    func toggleQuickDictation() {
        guard settings.promptHotkeyEnabled else { return }
        quickDictation.toggle()
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
    /// resolution only re-runs when one of THESE fields changes, so an overlay
    /// font/opacity slider tick does not cancel and relaunch it on every step.
    private var lastTranslationKey = ""

    private func applySettings() {
        guard !AppEnvironment.isUIFixture else { return }
        echoLock.withLock { micSuppressionEnabled = settings.suppressMicDuringSystemAudio }
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
        applyDictationHotkey()
        // Only if it already exists. `applySettings()` runs from `init`, so an
        // unconditional call would construct the composer — a `MicCapture`, an
        // `AVAudioEngine` and a rulebook decode — at launch for a user who may
        // never open the Prompt tab. Values are read live through a closure, so
        // this is only a re-render nudge.
        if isComposerLoaded { composer.apply(previous: previousSettings) }
        previousSettings = settings
        // Turning correction off mid-meeting drops the backlog so it can't keep
        // the model busy. A generation already in flight is left to finish and
        // land — it is a valid repair, and cancelling it would waste the work.
        if !settings.transcriptCorrectionEnabled { correctionQueue.removeAll() }
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
        prepareForCaptions()
    }

    @Published private(set) var captionPrewarmInProgress = false
    private var captionWarmSelection: String?

    func prepareForCaptions(refresh: Bool = false) {
        guard !AppEnvironment.isUIFixture, !controlWindowClosed, !isSharedModelBusy,
              !audioSourcesLocked else { return }
        let language = settings.firstLanguage
        let tier = settings.asrTier
        let selection = "\(language)|\(tier)"
        guard refresh || captionWarmSelection != selection else { return }
        captionWarmSelection = selection
        let accepted = asr.prewarmCachedVariant(language: language, tier: tier)
        captionPrewarmInProgress = accepted && !asr.isWarm && asr.modelLoadFailure == nil
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
        // Say WHICH combination is missing: every latency tier is a separate
        // ~600 MB model file, and Latin vs. multilingual are separate sets again,
        // so "the model for this language" alone reads as a bug when the tier is
        // what actually changed.
        modelStatus = "「\(settings.firstLanguage) · \(settings.asrTier)」的辨識模型尚未下載（約 600 MB）"
            + "— 每個語言與延遲檔位各是一份模型。下次「開始」會自動下載，或關閉設定後於提示中先下載"
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
            translationMethod = .none; translation.enabled = false; await releaseQwen()
            translationStatus = "翻譯語言：已關閉"
            return
        }
        guard settings.needsTranslation else {
            translationMethod = .none; translation.enabled = false; await releaseQwen()
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
            await releaseQwen()
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
            // reload the whole 2.3 GB model after we just freed it.
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
                // Translation just freed the model; if nothing took its place the
                // correction backlog finally gets a turn.
                self.pumpCorrectionQueue()
            }
            // Load the model into memory on first use (already on disk from Start).
            guard await self.ensureQwenReadyForTranslation(srcName: srcName, tgtName: tgtName) else { return }
            guard !Task.isCancelled else { return }
            guard let translated = await self.mlxTranslator.translate(
                next.text, target: target, context: context) else { return }
            self.applyTranslation(id: next.id, chinese: translated)
        }
        inflightTranslations[next.id] = task
    }

    // MARK: - Transcript correction (accurate track)

    /// Queue a finalized sentence for LLM repair. Sentences too short to hold a
    /// repairable error are filtered out here rather than costing a generation.
    private func enqueueCorrection(id: UUID, text: String) {
        guard settings.transcriptCorrectionEnabled, acceptingCorrections,
              TranscriptCorrectionGate.shouldAttempt(text) else { return }
        correctionQueue.append(PendingCorrection(id: id, text: text))
        if correctionQueue.count > correctionQueueLimit {
            correctionQueue.removeFirst(correctionQueue.count - correctionQueueLimit)
        }
        pumpCorrectionQueue()
    }

    /// Start the next queued correction — but only while no translation is
    /// running or waiting. Live captions always win the model; a correction is
    /// never on screen, so making a viewer wait for one would be indefensible.
    /// Starved corrections are simply dropped by the queue bound.
    private func pumpCorrectionQueue() {
        guard !correctionRunning, acceptingCorrections,
              settings.transcriptCorrectionEnabled, !correctionQueue.isEmpty,
              !mlxRunning, mlxQueue.isEmpty else { return }
        let next = correctionQueue.removeFirst()
        correctionRunning = true
        // The surrounding lines carry the recurring names this sentence may
        // repeat. Corrections lag the live captions, so these are usually the
        // sentences AFTER it — later context is just as good for a proper noun.
        let context = lines.suffix(3).filter { $0.id != next.id }.map(\.english)
        inflightCorrection = Task { [weak self] in
            guard let self else { return }
            defer {
                self.inflightCorrection = nil
                self.correctionRunning = false
                self.pumpCorrectionQueue()
            }
            guard !Task.isCancelled else { return }
            // Never WAIT for the model here. Correction is the low-priority track: if the
            // model isn't resident it starts the load and skips this sentence,
            // and the next one lands once it's warm.
            guard self.qwenReadyForCorrection() else { return }
            guard let repaired = await self.corrector.correct(
                next.text, context: context) else { return }
            guard !Task.isCancelled else { return }
            self.applyCorrection(id: next.id, corrected: repaired)
        }
    }

    /// Land a repair on the accurate track ONLY: the transcript window, the
    /// stored session, and everything downstream of it (summary, exports).
    ///
    /// The floating overlay is deliberately left alone — that line has already
    /// been read, and rewriting it under the viewer's eyes is exactly the jitter
    /// the caption-band design exists to prevent.
    ///
    /// The second caption is NOT re-translated: it was produced from the raw
    /// recognition and stays that way. Re-translating would mean a second
    /// generation per repaired sentence, competing with live subtitles for the
    /// one model — the record gains the corrected source text, and the
    /// translation of a repaired homophone rarely changes meaning.
    private func applyCorrection(id: UUID, corrected: String) {
        if let i = lines.firstIndex(where: { $0.id == id }) {
            lines[i].english = corrected
        }
        store.updateSourceText(segmentId: id, corrected: corrected)
    }

    /// Cancel and await any running correction, then drop the backlog — so no
    /// generation is still on the GPU when the shared Qwen model is unloaded.
    private func drainCorrections() async {
        correctionQueue.removeAll()
        let task = inflightCorrection
        inflightCorrection = nil
        task?.cancel()
        await task?.value   // its `defer` clears `correctionRunning`
    }

    // MARK: - ASR events

    private func handle(_ event: TranscriptEvent) {
        // Drop events that arrive after the meeting ended (the pipeline's trailing
        // finalize can land late) so they can't repopulate the UI or write into an
        // already-ended session. `.warming` still accepts: buffered audio replays
        // while the model finishes loading.
        guard asrState.isMeetingActive else { return }
        switch event {
        case .interim(let text, let source, let at, let utteranceId):
            handleInterim(text: text, source: source, at: at, utteranceId: utteranceId)
        case .previewFinal(let segment):
            guard let id = segment.utteranceId else { return }
            let text = TraditionalChineseGuard.normalizingScript(cleaner.cleanup(segment.text))
            if utteranceIds[segment.source] != id, !text.isEmpty,
               (lastInterimAudioTime[segment.source] ?? -.infinity) <= segment.utteranceEndTime {
                // A short reply may have its first usable text only at decoder
                // finalization. It still appears before speaker analysis.
                handleInterim(text: text, source: segment.source, at: segment.utteranceEndTime,
                              utteranceId: id)
            }
            if overlay.model.band.line(for: id) != nil {
                overlay.model.previewOriginalFinal(utteranceId: id, text: text,
                                                   expectsTranslation: settings.needsTranslation)
            }
        case .finalized(let segment):
            handleFinalized(segment)
        case .finalizedGroups(let segments):
            for segment in segments { handleFinalized(segment) }
        }
    }

    /// Live partial. Both sources record their partial; only the arbiter's owner
    /// drives the displayed interim (main window + overlay slot).
    private func handleInterim(text: String, source: AudioSourceType, at: TimeInterval,
                               utteranceId: UUID?) {
        // The audio time this partial covers, kept so a *late* finalize can tell
        // whether the partial on screen still belongs to it. Same clock as
        // `ASRSegment.endTime` — both are the capture chunk's timestamp.
        lastInterimAudioTime[source] = at
        let now = Date().timeIntervalSinceReferenceDate
        // Same script normalization the finalize path does, and for the same
        // reason — done here so every consumer below sees one form of the text.
        //
        // Only `handleFinalized` had it, and the model has exactly one Mandarin
        // tag (`zh-CN`, writing Simplified), so selecting 中文 gave a live caption
        // in Simplified that flipped to Traditional the instant the sentence
        // ended. Nothing downstream could compensate: `sourceIsTraditionalChinese`
        // is true for any `zh` prefix, so `needsTranslation` is false and there is
        // no second caption to carry the Traditional text either.
        //
        // Cheap enough for the partial rate: the detector skips any scalar outside
        // the Han range before it asks ICU anything, and caches per character.
        let text = TraditionalChineseGuard.normalizingScript(text)
        interimBySource[source] = text
        let id = utteranceId ?? utteranceIds[source] ?? UUID()
        let isNewUtterance = utteranceIds[source] != id
        utteranceIds[source] = id

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

    /// One finalized ASR utterance stays one bilingual paragraph, from partial
    /// through persistence and roll-up. Splitting it at punctuation used to evict
    /// the start of a multi-sentence paragraph and translate every piece again.
    private func handleFinalized(_ segment: ASRSegment) {
        let now = Date().timeIntervalSinceReferenceDate
        let source = segment.source
        let activeUtterance = utteranceIds[source]
        // Whether the partial currently on screen is *this* segment's, or already
        // belongs to the sentence after it. See `lastInterimAudioTime`.
        let partialIsNewer = segment.position == .earlierGroup
            || (segment.utteranceId != nil && activeUtterance != nil
                && segment.utteranceId != activeUtterance)
            || (lastInterimAudioTime[source] ?? -.infinity) > segment.utteranceEndTime
        let uttId = partialIsNewer ? nil : activeUtterance
        if !partialIsNewer {
            utteranceIds[source] = nil
            interimBySource[source] = nil
            lastInterimAudioTime[source] = nil
        }
        // A segment that no longer owns the live line is history, not the thing
        // being displayed — so it must not take the interim's slot or blank the
        // translation being shown for the sentence still in progress.
        let wasDisplayed = !partialIsNewer && interimArbiter.current == source
        // The arbiter is told the source stopped only when it actually did. A
        // source still emitting partials for the next sentence has not finished
        // speaking, and handing the live line to the other source here made the
        // caption flip mid-utterance.
        let nextOwner = partialIsNewer ? interimArbiter.current : interimArbiter.end(source, at: now)

        // No active session (extreme timing edge) → nothing to attribute the
        // segment to; never invent a random session id (FR-008 integrity).
        guard let session = currentSession else { return }
        // Keep the whole cleaned paragraph, including its original punctuation
        // and spacing. The splitter is only a usability check for filler-only /
        // punctuation-only output; it no longer changes the display unit.
        let recognized = TraditionalChineseGuard.normalizingScript(cleaner.cleanup(segment.text))
        guard !SentenceSplitter.split(recognized).isEmpty else {
            // Nothing usable — pure filler, or punctuation the recognizer emitted
            // with no words behind it. Clear the displayed interim AND the band
            // slot; otherwise a caret line would linger forever.
            if wasDisplayed { clearDisplayedInterim() }
            if let uttId { overlay.model.applyDiscard(utteranceId: uttId) }
            promoteNextInterim(nextOwner)
            return
        }

        let provisional = wasDisplayed && segment.position == .whole && !interimChinese.isEmpty
            ? interimChinese : nil
        let displayId = segment.utteranceId ?? (segment.position == .earlierGroup ? activeUtterance : uttId)
        let displayed = displayId.flatMap { overlay.model.band.line(for: $0) }
        let expiredPreview = displayed == nil
            && displayId.map { overlay.model.band.hasPresented($0) } == true
        let hasReadRows = displayed.map {
            $0.id != overlay.model.band.slot?.id || $0.originalRows.rows.count > 1
        } ?? false
        let keepsGroupedPreview = hasReadRows && segment.position != .whole
        if wasDisplayed {
            clearDisplayedInterim()
            // A full-utterance partial translation cannot be attached to just
            // the last speaker's words. Retire that partial before committing.
            if segment.position == .lastGroup, !keepsGroupedPreview, let uttId {
                overlay.model.applyDiscard(utteranceId: uttId)
            }
        }
        let speaker = speakerName(for: segment.speakerLabel, source: source)
        let retainedId = segment.position == .whole && displayed != nil ? displayId : nil
        let id = retainedId ?? (wasDisplayed ? uttId : nil) ?? UUID()
        lines.append(CaptionLine(id: id, english: recognized, chinese: provisional,
                                 source: source, timestamp: Date(), speakerLabel: speaker?.full))
        store.append(TranscriptSegment(
            id: id, sessionId: session.id, index: segmentIndex,
            startTime: segment.startTime, endTime: segment.endTime,
            source: source, speakerLabel: speaker?.full, sourceText: recognized))
        segmentIndex += 1
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        if wasDisplayed || overlay.model.band.slot?.isFinal != false { currentOverlayId = id }

        // Install the key before an exact cached translation or instant phrase
        // can synchronously return. The same identity now owns the whole text.
        if !expiredPreview {
            if keepsGroupedPreview, let displayId {
                overlay.model.addPresentedSpeakerGroup(
                    utteranceId: displayId, key: id, original: recognized,
                    speaker: speaker?.full, isLast: segment.position == .lastGroup)
            } else {
                overlay.model.applyCommit(
                    utteranceId: retainedId ?? (wasDisplayed ? uttId : nil), source: source,
                    sentences: [(key: id, english: recognized)],
                    expectsTranslation: settings.needsTranslation, speakerLabel: speaker?.full,
                    provisional: provisional.map { [id: $0] } ?? [:])
            }
        }
        translateSentence(id: id, text: recognized)
        enqueueCorrection(id: id, text: recognized)

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
        lastInterimAudioTime = [:]
        speakerNamer.reset()
        interimArbiter.reset()
        interimZhStable.reset()
        mlxContext.reset()
        mlxQueue.removeAll()
    }

    // MARK: - Recognition / meeting lifecycle

    /// A cold native load may exceed the short audio buffer: wait for readiness.
    private static let warmingMessage = "本機 ASR 準備中…請等候辨識就緒再說話；可按「結束」取消"
    private static let listeningMessage = "辨識中 Listening"

    var captionModelLoadFailed: Bool { asrState == .warming && asr.modelLoadFailure != nil }

    /// Readiness belongs to the current shared load, never an accumulated count
    /// of obsolete loads. A failed load must not report Listening.
    private func refreshWarmingState() {
        switch asrState {
        case .warming:
            if asr.isWarm {
                asrState = .listening
                statusMessage = Self.listeningMessage
            } else if let failure = asr.modelLoadFailure {
                statusMessage = "模型載入失敗：\(failure)。可按「結束」後重新開始。"
                overlay.model.listenState = .failed
            }
        case .listening:
            if !asr.isWarm {
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
        if let d = diarDownloadPct, d < 100 { parts.append("講者模型 \(d)%") }
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

    private var recognitionStartTask: Task<Void, Never>?
    private var recognitionGeneration: UInt64 = 0

    func startRecognition() async {
        // Idle only — and never while a summary is running (its `releaseQwen()`
        // would race a new meeting's translations: GPU.clearCache hazard) or
        // while the launch-time bulk download runs (two concurrent downloads of
        // the same ASR variant would corrupt the cache).
        guard !isClosingResources, recognitionStartTask == nil, asrState == .idle, !isSummarizing,
              !isDownloadingModels, !isResettingPermissions else { return }
        recognitionGeneration &+= 1
        let startupToken = recognitionGeneration
        asrState = .loading
        let task = Task { [self] in await prepareRecognition(startupToken: startupToken) }
        recognitionStartTask = task
        await task.value
        if recognitionStartTask == task { recognitionStartTask = nil }
    }

    private func prepareRecognition(startupToken: UInt64) async {
        let began = ContinuousClock.now
        // The Prompt tab shares this ASR service and the Qwen host, so a compile
        // in flight has to be cancelled AND awaited before the meeting touches
        // either — unloading the Qwen container mid-generation is the known
        // GPU.clearCache crash, and the composer also owns `asr.onEvent` while
        // it dictates. The eval runner too: it is 22 consecutive generations on
        // the same host, so starting a meeting without draining it left the
        // longest of the three running straight into `loadModels`.
        await drainPromptWorkloads()
        guard startupToken == recognitionGeneration, !Task.isCancelled, !isResettingPermissions else { return }
        Self.log.notice("Caption startup prompt cleanup: \(String(describing: ContinuousClock.now - began), privacy: .public)")
        asrDownloadPct = nil
        composeLoadingStatus()
        // Fail fast when the selected variant needs downloading but we're offline
        // (a clear message instead of a 60 s+ URLSession hang at "0%").
        if !NemotronStreamingService.variantPresent(
            language: settings.firstLanguage, tier: settings.asrTier) {
            let online = await NetworkCheck.isOnline()
            guard startupToken == recognitionGeneration, !Task.isCancelled, !isResettingPermissions else { return }
            guard online else {
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
            asr.diarizationEnabled = settings.diarizationEnabled
            asr.diarizationSensitivity = settings.diarizationSensitivity
            asr.keepAcousticContext = settings.keepAcousticContext
            asr.onLoadProgress = { [weak self] p in
                Task { @MainActor in
                    guard let self, self.recognitionGeneration == startupToken else { return }
                    self.asrDownloadPct = Int(p * 100)
                    self.composeLoadingStatus()
                }
            }
            try await asr.loadModels(tier: settings.asrTier)
            guard startupToken == recognitionGeneration, !Task.isCancelled, !isResettingPermissions else { return }
            Self.log.notice("Caption startup disk and speaker preparation finished at \(String(describing: ContinuousClock.now - began), privacy: .public)")
            router.beginSession()
            try await asr.startStream()
            guard startupToken == recognitionGeneration, !Task.isCancelled, !isResettingPermissions else { return }
            currentSession = store.beginSession(settings: settings)
            Self.log.notice("Caption startup transcript ready at \(String(describing: ContinuousClock.now - began), privacy: .public)")
            segmentIndex = 0
            lines.removeAll()
            summaryText = ""
            lastSummaryEN = nil
            lastSummaryZH = nil
            interimText = ""
            acceptingTranslations = true
            acceptingCorrections = true
            correctionQueue.removeAll()
            qwenLoadFailures = 0
            asrDownloadPct = nil
            resetLiveCaptionState()
            overlay.model.clear()
            // Honest state: the files are on disk but the model memory-load runs
            // in the background (startStream kicked it off). Show "warming" until
            // it's resident; `refreshWarmingState` flips to listening when the
            // pending load completes. If the model is already resident (isWarm)
            // and nothing is loading, go straight to listening.
            if asr.isWarm {
                asrState = .listening
                statusMessage = Self.listeningMessage
            } else {
                asrState = .warming
                statusMessage = Self.warmingMessage
                refreshWarmingState()
            }
        } catch {
            guard startupToken == recognitionGeneration, !Task.isCancelled else { return }
            asrState = .idle
            asrDownloadPct = nil
            statusMessage = "模型載入失敗：\(Self.humanizeError(error))。再按一次「開始」即可重試。"
        }
    }

    private func cancelRecognitionStartup() {
        recognitionGeneration &+= 1
        recognitionStartTask?.cancel()
        recognitionStartTask = nil
        asr.cancelStream(keepModelsResident: true)
        asrState = .idle
    }

    // MARK: - Model preflight / uninstall

    /// Whether all on-disk models are present — ASR, Silero VAD, Qwen, and the
    /// pyannote diarization pair when that setting is on (it now is by default).
    /// Checked for the **currently selected** first language + tier, not just any
    /// cached variant: every language/tier pair is a separate ~600 MB download.
    var modelsPresent: Bool {
        NemotronStreamingService.variantPresent(
            language: settings.firstLanguage, tier: settings.asrTier)
            && NemotronStreamingService.vadModelPresent
            && (!settings.diarizationEnabled || NemotronStreamingService.diarizationModelPresent)
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
                timestamp: recovered.session.startedAt.addingTimeInterval(seg.startTime),
                speakerLabel: seg.speakerLabel)   // persisted; dropping it blanked the speaker column
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
    /// the transcript durable before the process dies. Await the same stop/drain
    /// as the Stop button before flushing and replying to the OS.
    func prepareForTermination() async {
        terminationRequested = true
        await beginClosingResources().value
    }

    /// Download every model now (ASR variant, Silero VAD, Qwen, and the pyannote
    /// diarization pair when that setting is on), with progress.
    /// Idle-only: running this concurrently with a meeting's `loadModels` would
    /// double-download the same ASR variant into the same directory.
    func downloadAllModels() async {
        guard !isClosingResources, !isDownloadingModels, asrState == .idle else { return }
        guard await NetworkCheck.isOnline() else {
            statusMessage = "目前離線，無法下載模型。請連上網路後再試。"
            return
        }
        guard !isClosingResources, !controlWindowClosed, !isDownloadingModels,
              asrState == .idle else { return }
        isDownloadingModels = true
        showModelDownloadPrompt = false
        statusMessage = "Downloading models…"
        prefetchQwen()
        asr.currentLanguage = settings.firstLanguage
        asr.diarizationEnabled = settings.diarizationEnabled
        asr.diarizationSensitivity = settings.diarizationSensitivity
        asr.keepAcousticContext = settings.keepAcousticContext
        asr.onLoadProgress = { [weak self] p in
            Task { @MainActor in self?.statusMessage = "下載 ASR 模型… \(Int(p * 100))%" }
        }
        do { try await asr.loadModels(tier: settings.asrTier) } catch {
            statusMessage = "ASR 模型下載失敗：\(Self.humanizeError(error))"
        }
        _ = await asr.prefetchVAD()
        await qwenPrefetchTask?.value
        isDownloadingModels = false
        prepareForCaptions(refresh: true)
        statusMessage = modelsPresent
            ? "模型已就緒 Models ready"
            : "部分模型仍未下載 — 請檢查網路後重試 Some models still missing"
    }

    /// Delete private models + app data, remove the app's privacy (TCC)
    /// entries so a reinstall prompts fresh instead of hitting a stale toggle,
    /// move the app to the Trash, and quit.
    func uninstall() {
        guard !AppEnvironment.isUIFixture else { return }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // FluidAudio is shared with other apps. Uninstall must not remove its
        // ASR/VAD/speaker cache or unrelated models owned by another project.
        try? fm.removeItem(at: appSupport.appendingPathComponent("FlowTranslate", isDirectory: true))
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        } else {
            UserDefaults.standard.removeObject(forKey: "FlowTranslate.CaptionSettings")
        }
        Permissions.resetPrivacyPermissions()
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        AppDelegate.requestTermination()
    }

    /// Manually clear this app's privacy entries — Microphone, Screen Recording
    /// and Accessibility (Settings → Maintenance). Fixes the
    /// stale-permission state after replacing the app with a new build: the
    /// Privacy toggle looks ON but capture fails until the old entry is removed.
    /// Stops active sources first, since their grants are being revoked.
    @discardableResult
    func resetPrivacyPermissions(services: [String]? = nil) async -> Permissions.ResetReport {
        if let task = permissionResetTask { return await task.value }
        isResettingPermissions = true
        let resetsMic = services?.contains("Microphone") ?? true
        let resetsSystem = services?.contains("ScreenCapture") ?? true
        if resetsMic { sourceGenerations[.microphone, default: 0] &+= 1 }
        if resetsSystem { sourceGenerations[.system, default: 0] &+= 1 }
        let task = Task { [self] in
            if asrState == .loading { cancelRecognitionStartup() }
            // A dictation may own the microphone while micEnabled is false.
            // Return its lease before disabling capture, without calling the
            // user toggles (which intentionally reject changes during dictation).
            await drainPromptWorkloads()
            await endMeeting()
            if resetsMic {
                router.disable(.microphone)
                micEnabled = false
                levels.mic = 0
            }
            if resetsSystem {
                router.disable(.system)
                systemEnabled = false
                levels.system = 0
                echoLock.withLock { systemSourceOn = false }
            }
            let report = AppEnvironment.isUIFixture
                ? Permissions.ResetReport()
                : Permissions.resetPrivacyPermissions(services: services)
            statusMessage = report.summary
            statusAction = nil
            return report
        }
        permissionResetTask = task
        // The report's own summary, not a verdict derived from it: collapsing the
        // services into one boolean is wrong when only some fail, and a fixed "run
        // these by hand" line is useless when the reason is that `tccutil` cannot
        // resolve the bundle identifier.
        //
        // Returned as well as posted to the status line: the caller is a sheet
        // that stays open, and the status line is on the window behind it.
        let report = await task.value
        permissionResetTask = nil
        isResettingPermissions = false
        return report
    }

    @Published private(set) var isResettingPermissions = false
    private var permissionResetTask: Task<Permissions.ResetReport, Never>?
    private var sourceGenerations: [AudioSourceType: UInt64] = [:]

    /// Every Stop/window-close/Quit caller awaits the same completion.
    private let meetingStop = MeetingStopCoordinator()

    func endMeeting() async {
        if asrState == .loading {
            cancelRecognitionStartup()
            statusMessage = "已取消準備 Cancelled"
            return
        }
        guard asrState.isMeetingActive || meetingStop.isRunning else { return }
        await meetingStop.run { [self] in await finishMeeting() }
    }

    private func finishMeeting() async {
        let cancelledColdLoad = asrState == .warming && !asr.isWarm
        let modelLoadFailure = asr.modelLoadFailure
        statusMessage = "結束中… Stopping"
        // Includes pending cold-start audio, final decoding and delivery on the
        // MainActor. Keep the session active until the last event is stored.
        if cancelledColdLoad {
            // No recognizer exists to drain yet. Cancel this session's pending
            // audio immediately, while retaining the single shared native load
            // so a subsequent Start cannot launch a duplicate CoreML compile.
            asr.cancelStream(keepModelsResident: true)
        } else {
            asr.stopStream(keepModelsResident: true)
            await asr.drain()
        }
        acceptingCorrections = false
        // The ASR's last final can just have queued a translation. Complete
        // accepted final sentences instead of cancelling them during unload.
        // New live audio has stopped, so this cannot grow without bound.
        if translationMethod == .mlx {
            statusMessage = "完成最後翻譯中… Finishing translations"
            while !mlxQueue.isEmpty || !inflightTranslations.isEmpty {
                pumpMLXQueue()
                let tasks = Array(inflightTranslations.values)
                guard !tasks.isEmpty else { break } // backend changed/unavailable
                for task in tasks { await task.value }
            }
        }
        // Stop accepting new work first, so nothing can be queued behind the
        // drain that `releaseQwen()` performs before it frees the model.
        acceptingTranslations = false
        await releaseQwen()       // drains both queues, then frees the model
        store.endSession()
        asrState = .idle
        interimText = ""
        interimChinese = ""
        resetLiveCaptionState()
        overlay.model.clear()
        prepareForCaptions()
        if settings.autoCloseOverlayOnStop { overlayOn = false }   // opt-in (Settings)
        // Keep `lines` (the transcript) so it can be summarized / exported on demand.
        if let modelLoadFailure {
            statusMessage = "模型載入失敗：\(modelLoadFailure)。可按「開始」重試。"
        } else {
            statusMessage = cancelledColdLoad
                ? "已取消尚未就緒的辨識 Cancelled · 未辨識的音訊已捨棄，模型仍在背景準備"
                : "已結束 Done · 可按「摘要 Summary」產生摘要"
        }
    }

    /// Whether a finished-meeting transcript is available to summarize on demand
    /// (drives the Summary button: only after a meeting has ended, with content).
    var canSummarize: Bool {
        // The prompt checks are not optional: those features hold the same Qwen
        // host, and summarizing while one is generating would unload the
        // container mid-flight. `busyPromptWorkloads` answers without building
        // anything, so this no longer depends on evaluation order to stay lazy —
        // which is what the previous version needed a paragraph to explain and
        // three other call sites broke anyway.
        guard !isClosingResources, asrState == .idle, !isSummarizing, currentSession != nil, !lines.isEmpty
        else { return false }
        return !busyPromptWorkloads
    }

    /// Manually generate the bilingual summary for the just-ended meeting. Loads the
    /// Qwen model on demand and frees it afterwards, so the heavy summary never runs
    /// (and never slows a new real-time session) unless the user asks for it.
    func generateSummary() async {
        guard canSummarize else { return }
        isSummarizing = true
        let task = Task { [self] in await runSummary() }
        summaryTask = task
        await task.value
    }

    private var summaryTask: Task<Void, Never>?

    private func runSummary() async {
        defer {
            summaryTask = nil
            isSummarizing = false
            prepareForCaptions(refresh: true)
        }
        asr.releaseModels()       // summary needs memory; idle meetings reuse ASR weights
        captionPrewarmInProgress = false
        statusMessage = "產生摘要中… Generating summary…"
        await summarize()
        if !isClosingResources { await releaseQwen(summaryFinished: true) }
        guard !Task.isCancelled else { return }
        // Honest completion status: `summarize()` can fail on both backends.
        statusMessage = summaryText.isEmpty
            ? "摘要失敗 Summary failed · 請再試一次（記憶體不足或模型未下載）"
            : "摘要完成 Summary ready"
    }

    private func summarize() async {
        guard let session = currentSession else { return }
        var pair: (english: Summary, chinese: Summary)?
        do {
            // Make sure the at-Start disk prefetch finished so the summarizer loads
            // from cache instead of starting its own concurrent download.
            if let prefetch = qwenPrefetchTask {
                _ = await CancellableTaskWait.wait(for: prefetch)
            }
            try Task.checkCancellation()
            statusMessage = "產生摘要中 Generating summary (Qwen3-4B)…"
            pair = try await mlxSummarizer.summarizeBilingual(session: session, segments: store.segments) { p in
                Task { @MainActor in self.statusMessage = "Summarizing… \(Int(p * 100))%" }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            // MLX unavailable (offline / first-run download failed / low memory):
            // fall back to the on-device extractive summary so the user still gets one.
            Self.log.error("Qwen summary failed: \(String(reflecting: error), privacy: .public)")
            modelStatus = "Qwen 摘要無法產生，改用內建摘要（Qwen summary unavailable, using built-in fallback）"
            statusMessage = "改用內建摘要 Using built-in summary…"
            pair = try? await fallbackSummarizer.summarizeBilingual(session: session, segments: store.segments, progress: nil)
        }

        guard let pair, !Task.isCancelled else { return }
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
    private let controlWindows = NSHashTable<NSWindow>.weakObjects()
    private var windowCloseObserver: NSObjectProtocol?
    private var controlWindowClosed = false
    private var terminationRequested = false
    private var closeResourcesTask: Task<Void, Never>?
    private var isClosingResources: Bool { terminationRequested || closeResourcesTask != nil }

    /// Observe the main control window's close so that closing it stops capturing and
    /// hides the overlay (the app stays running for a quick reopen). Filtered to the
    /// exact window, so closing the Settings sheet doesn't trigger it.
    var audioSourcesLocked: Bool { isClosingResources || busyPromptWorkloads || isResettingPermissions }

    /// Capture the presenting window once. NSApp.mainWindow can become the
    /// sheet itself, causing its dimensions to shrink on subsequent refreshes.
    var settingsPresentationSize: CGSize {
        let available = boundWindow?.contentLayoutRect.size
            ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 640, height: 740)
        return CGSize(width: min(560, max(320, available.width - 40)),
                      height: min(660, max(320, available.height - 40)))
    }

    func bindMainWindow(_ window: NSWindow?) {
        guard let window, !controlWindows.contains(window),
              !controlWindowClosed || window.isVisible else { return }
        let reopening = controlWindowClosed
        controlWindowClosed = false
        boundWindow = window
        controlWindows.add(window)
        if let visible = window.screen?.visibleFrame {
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
        if windowCloseObserver == nil {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let closing = notification.object as? NSWindow,
                          self.controlWindows.contains(closing) else { return }
                    self.controlWindows.remove(closing)
                    if self.boundWindow === closing { self.boundWindow = self.controlWindows.anyObject }
                    if self.controlWindows.count == 0 { self.handleWindowClosed() }
                }
            }
        }
        if reopening { prepareForCaptions(refresh: true) }
    }

    private func handleWindowClosed() {
        controlWindowClosed = true
        boundWindow = nil
        _ = beginClosingResources()
    }

    private func beginClosingResources() -> Task<Void, Never> {
        if let closeResourcesTask { return closeResourcesTask }
        overlayOn = false
        captionPrewarmInProgress = false
        summaryTask?.cancel()
        for source in AudioSourceType.allCases {
            sourceGenerations[source, default: 0] &+= 1
            router.disable(source)
        }
        micEnabled = false
        systemEnabled = false
        levels.mic = 0
        levels.system = 0
        echoLock.withLock { systemSourceOn = false }

        let task = Task { [self] in
            await endMeeting()
            await summaryTask?.value
            acceptingTranslations = false
            acceptingCorrections = false
            await releaseQwen()
            // A dictation lease may restore a previously enabled mic as it drains.
            for source in AudioSourceType.allCases { router.disable(source) }
            asr.releaseModels()
            (store as? FileTranscriptStore)?.flush()
            Self.log.notice("Control resources released: ASR resident=\(self.asr.isWarm), Qwen resident=\(self.qwenHost.isLoaded), active sources=\(self.router.activeSources.count)")
            closeResourcesTask = nil
            prepareForCaptions(refresh: true)
        }
        closeResourcesTask = task
        return task
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
        s.overlayBottomAnchor = nil
        settings = s
    }

    // MARK: - Export

    /// File extension and display name for each export format.
    private static func exportFileType(_ format: ExportFormat) -> (ext: String, label: String) {
        switch format {
        case .markdown:  return ("md", "Markdown")
        case .plainText: return ("txt", "Plain text")
        case .srt:       return ("srt", "SRT subtitles")
        case .vtt:       return ("vtt", "WebVTT subtitles")
        case .json:      return ("json", "JSON")
        }
    }

    /// Export the transcript. The format follows the extension the user picks in
    /// the save panel, so all five `TranscriptExporter` produces are reachable.
    func exportTranscript() {
        guard let session = currentSession else { return }

        let panel = NSSavePanel()
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f.string(from: Date()) }()
        panel.nameFieldStringValue = "FlowTranslate-\(stamp).md"
        panel.canCreateDirectories = true
        panel.title = "匯出逐字稿 Export transcript"
        panel.message = "副檔名決定格式 The extension picks the format: "
            + ExportFormat.allCases.map { Self.exportFileType($0).ext }.joined(separator: " · ")
        panel.allowedContentTypes = ExportFormat.allCases.compactMap {
            UTType(filenameExtension: Self.exportFileType($0).ext)
        }
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // Map the chosen extension back to a format; anything unexpected
            // falls back to Markdown rather than failing the export.
            let chosen = url.pathExtension.lowercased()
            let format = ExportFormat.allCases.first { Self.exportFileType($0).ext == chosen } ?? .markdown
            do {
                let data = try TranscriptExporter().exportBilingual(
                    session: session, segments: self.store.segments,
                    chinese: self.lastSummaryZH, english: self.lastSummaryEN, format: format)
                try data.write(to: url)
                self.statusMessage = "Exported \(Self.exportFileType(format).label) to \(url.path)"
            } catch {
                self.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Audio sources

    func toggleMic() async {
        guard !audioSourcesLocked else { return }
        let token = sourceGenerations[.microphone, default: 0]
        if micEnabled {
            router.disable(.microphone); micEnabled = false; levels.mic = 0
            return
        }
        // One shared rule with the dictation path: asked once when macOS has
        // never been asked, never again after a grant.
        let granted = await Permissions.ensureMicrophone()
        guard token == sourceGenerations[.microphone, default: 0] else { return }
        guard granted else {
            // Offered, not opened. Once macOS has recorded a denial,
            // `requestAccess` returns false without ever showing a dialog again,
            // so System Settings is the only thing that can change the answer —
            // but going there is the user's decision to make, not a side effect of
            // flipping a switch. The button is right beside the message.
            statusMessage = "麥克風權限被拒 Microphone denied — "
                + "系統設定 → 隱私權與安全性 → 麥克風"
            statusAction = .microphone
            return
        }
        do {
            try await router.enable(.microphone)
            guard token == sourceGenerations[.microphone, default: 0] else {
                return
            }
            micEnabled = true
            statusMessage = "麥克風已開啟"
        } catch is CancellationError {
            return
        } catch {
            guard token == sourceGenerations[.microphone, default: 0] else { return }
            statusMessage = "麥克風啟動失敗: \(error.localizedDescription)"
        }
    }

    func toggleSystem() async {
        guard !audioSourcesLocked else { return }
        let token = sourceGenerations[.system, default: 0]
        if systemEnabled {
            router.disable(.system); systemEnabled = false; levels.system = 0
            echoLock.withLock { systemSourceOn = false }
        } else {
            let granted = await Permissions.requestScreenRecordingOnce()
            guard token == sourceGenerations[.system, default: 0] else { return }
            guard granted else {
                // The advice changes after the first attempt. A grant is resolved
                // when the process starts, so "I turned it on and it still says
                // this" is the expected second attempt and the answer is a
                // relaunch — not the reset, which is for the different case where
                // a rebuilt binary no longer matches its TCC entry.
                //
                // Offered rather than opened, for the same reason `toggleMic`
                // offers: the pane is what unblocks this, and the trip there is
                // the user's to take.
                statusMessage = Permissions.screenRecordingHint
                statusAction = .screenRecording
                return
            }
            do {
                try await router.enable(.system)
                guard token == sourceGenerations[.system, default: 0] else {
                    return
                }
                systemEnabled = true
                echoLock.withLock { systemSourceOn = true }
            } catch is CancellationError {
                return
            } catch {
                guard token == sourceGenerations[.system, default: 0] else { return }
                statusMessage = "系統音訊啟動失敗：\(error.localizedDescription) · 請確認螢幕錄製權限並重新啟動 App"
                statusAction = .screenRecording
            }
        }
    }

    private func updateLevel(_ source: AudioSourceType, _ rms: Float) {
        switch source {
        case .microphone: levels.mic = rms
        case .system: levels.system = rms
        }
    }

    // MARK: - Session bookkeeping

    private var currentSession: Session?

    private var fixtureReplay: Task<Void, Never>?

    /// Exercise the real transcript and overlay views without capture, model
    /// loading or production data. Available only in isolated fixture bundles.
    func replayCaptionUIFixture() {
        guard AppEnvironment.isUIFixture else { return }
        fixtureReplay?.cancel()
        summaryText = ""
        lines = (1...100).map { index in
            CaptionLine(id: UUID(), english: "Sentence \(index): bilingual caption replay.",
                        chinese: "第 \(index) 句：雙語字幕版面測試。")
        }
        overlayOn = true
        overlay.model.clear()
        fixtureReplay = Task { [weak self] in
            for index in 101...110 {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let self else { return }
                self.lines.append(CaptionLine(id: UUID(), english: "LATEST \(index): automatically following new captions.",
                                              chinese: "最新第 \(index) 句：字幕應自動捲到這裡。"))
            }
            for index in 1...8 {
                guard let self else { return }
                let id = UUID()
                self.overlay.model.applyInterim(utteranceId: id, source: .system,
                                               english: "Live sentence \(index)", chinese: "即時字幕第 \(index) 句",
                                               expectsTranslation: true)
                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                self.overlay.model.applyCommit(utteranceId: id, source: .system,
                                              sentences: [(key: id, english: "Final sentence \(index)")],
                                              expectsTranslation: true)
                self.overlay.model.applyTranslation(key: id, text: "完整字幕第 \(index) 句")
            }
        }
    }
}
