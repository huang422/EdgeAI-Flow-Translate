import AppKit
import Carbon.HIToolbox
import Foundation
import FlowTranslateCore
import os

/// Resolves which locale a dictation session should run in.
///
/// Following the meeting language is the default because it costs nothing:
/// the variant is already downloaded and already resident. `"auto"` handles
/// code-switching, but it selects the multilingual ship — free when the meeting
/// language is already non-Latin, an extra ~600 MB variant and a model reload
/// when it is English.
enum PromptDictation {
    /// The recognizer tier dictation runs at, regardless of the caption setting.
    ///
    /// FluidAudio's benchmark: 560 ms → 2.28% WER at 42.1× RTFx, 1120 ms → 2.28%
    /// at 65.0×, 2240 ms → 2.46% at 93.6×, noting "WER is neutral across tiers
    /// (within n=100 noise)". 1120 ms ties the best WER at 1.5× the throughput,
    /// and its encoder graph is cheaper to compile onto the ANE than 2240 ms's —
    /// that first-load compile is the wait the user feels. Chunk latency is what
    /// dictation can ignore, nothing being displayed until you stop.
    ///
    /// Both entry points must agree on this value, or the tab and the hotkey load
    /// two different ~600 MB variants and switching costs a reload every time.
    ///
    /// Source: FluidAudio `Documentation/Benchmarks.md`.
    static let tier = "1120ms"

    /// The recognizer locale for dictation, for whichever engine will run.
    ///
    /// An empty value is a setting saved before "follow the captions language"
    /// was removed; it maps to `auto`, so an upgrade does not silently make
    /// dictation follow something the app no longer offers.
    @MainActor
    static func language(for settings: CaptionSettings) -> String {
        language(for: settings, engine: DictationEngineFactory.resolved(settings))
    }

    /// The recognizer locale, for a named engine.
    ///
    /// The one place the stored language and the *model tag* may differ. The
    /// picker stores `zh-TW` for both engines; the rewrite below is **Nemotron's**
    /// alone, because no shipped Nemotron variant carries that tag — the language
    /// lock would search for it, fail, and the decoder would produce garbage. So
    /// recognition runs under `zh-CN` and `TraditionalChineseGuard` produces the
    /// Traditional output afterwards. macOS's recognizer has a real `zh-TW`, and
    /// applying the workaround there would ask for Simplified from an engine about
    /// to give us Traditional.
    static func language(for settings: CaptionSettings, engine: ResolvedDictationEngine) -> String {
        let configured = settings.promptDictationLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return "auto" }
        guard engine == .nemotron else { return configured }
        return configured == "zh-TW" ? "zh-CN" : configured
    }
}

/// The ⌃⌥Space flow: speak anywhere, get the result at the cursor.
///
/// Deliberately separate from the Prompt tab's view model so it never touches
/// the draft the user has open there. It shares the ASR service and Qwen host
/// through `DictationSession` and `QwenPromptCompiler`, so it adds no model
/// memory of its own.
@MainActor
final class QuickDictationController: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Fetching the recognizer's weights — only ever on a fresh install, and
        /// only the first time. Separate from `warming` because it is minutes
        /// rather than seconds and it has a number worth showing.
        case downloading(fraction: Double)
        case warming
        case listening
        /// Loading (or downloading) the language model the chosen mode needs.
        case preparingModel
        /// Input closed, waiting for the sentence still being decoded.
        ///
        /// Short — 600 ms — but its own phase rather than borrowing `listening` or
        /// `tidying`: `toggle()` decides what a second key press does from the
        /// phase, and either of those would make it do the wrong thing.
        case finishing
        /// Repairing the transcript before it reaches the compiler.
        ///
        /// A fraction rather than a sentence counter: the repair is one generation
        /// over the whole passage, so how much output has been produced is the
        /// only progress signal there is.
        case tidying(fraction: Double)
        case compiling(tokens: Int)
        case inserting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var interim: String = ""

    private let dictation: DictationSession
    private let compiler: QwenPromptCompiler
    private let repairer: PromptTextRepairer
    /// Drives the repair. Shared with the Prompt tab so both behave identically.
    private var tidier: TranscriptTidier {
        TranscriptTidier(repairer: repairer, prepareModel: preparingModelOnHUD)
    }

    /// `prepareModel`, with the wait shown on the panel rather than on the main
    /// window's status line — ⌃⌥Space is pressed from another application, so that
    /// line is by definition off screen. On a first run this wait is a 2.3 GB
    /// download.
    private var preparingModelOnHUD: (@MainActor () async -> String?)? {
        guard let prepareModel else { return nil }
        return { [weak self] in
            self?.set(.preparingModel)
            return await prepareModel()
        }
    }
    private let qwenHost: QwenModelHost
    private let cleaner = SpokenNoiseCleaner()
    private let hud = DictationHUDWindow()
    /// Names what is holding the shared models, or nil when nothing is.
    private let blockedBy: @MainActor () -> String?
    private var settingsProvider: @MainActor () -> CaptionSettings
    private var rulebookProvider: @MainActor () -> PromptRulebook
    /// Signals that the shared models are no longer needed.
    private let didFinishWork: @MainActor () -> Void
    /// Persists where the user dragged the HUD, so it reappears there.
    private let didMoveHUD: @MainActor (CGPoint) -> Void
    /// Persists a mode switched from the HUD itself.
    private let didChangeInsertMode: @MainActor (PromptQuickInsertMode) -> Void
    /// Loads the shared model through the owner, inheriting its failure budget,
    /// its single load task and its wait on the at-Start prefetch.
    private let prepareModel: (@MainActor () async -> String?)?
    private var work: Task<Void, Never>?

    private static let log = Logger(subsystem: "dev.flowtranslate.app", category: "prompt")

    init(
        asr: NemotronStreamingService,
        router: AudioRouter,
        qwenHost: QwenModelHost,
        blockedBy: @escaping @MainActor () -> String?,
        settings: @escaping @MainActor () -> CaptionSettings,
        rulebook: @escaping @MainActor () -> PromptRulebook,
        didFinishWork: @escaping @MainActor () -> Void = {},
        didMoveHUD: @escaping @MainActor (CGPoint) -> Void = { _ in },
        didChangeInsertMode: @escaping @MainActor (PromptQuickInsertMode) -> Void = { _ in },
        prepareModel: (@MainActor () async -> String?)? = nil
    ) {
        self.prepareModel = prepareModel
        self.dictation = DictationSession(router: router) { [settings] in
            DictationEngineFactory.make(
                for: settings(), asr: asr, tier: PromptDictation.tier
            )
        }
        self.compiler = QwenPromptCompiler(host: qwenHost)
        self.repairer = PromptTextRepairer(host: qwenHost)
        self.qwenHost = qwenHost
        self.blockedBy = blockedBy
        self.settingsProvider = settings
        self.rulebookProvider = rulebook
        self.didFinishWork = didFinishWork
        self.didMoveHUD = didMoveHUD
        self.didChangeInsertMode = didChangeInsertMode

        hud.restore(origin: settings().promptHUDPosition)
        hud.onPositionChanged = { [weak self] origin in self?.didMoveHUD(origin) }
        // The mode is read at insert time, not at start, so switching it from the
        // HUD mid-dictation applies to the sentence being spoken.
        hud.insertMode = { [weak self] in
            // The fallback matches `PromptQuickInsertMode`'s own default; one that
            // disagreed would only ever be visible once it was wrong.
            self?.settingsProvider().promptQuickInsertMode ?? .tidiedTranscript
        }
        hud.onInsertModeChanged = { [weak self] mode in self?.didChangeInsertMode(mode) }
        hud.onCancel = { [weak self] in self?.cancel() }

        dictation.onDownloadProgress = { [weak self] fraction in
            guard let self, self.phase == .warming || self.isDownloading else { return }
            // **A finished download is not a finished preparation.** The fraction
            // reaches 1 when the files are on disk; what follows on a fresh variant
            // is the CoreML load and the ANE compile, which report no progress at
            // all. `.warming` says "loading" where a frozen 100% says nothing.
            if fraction >= 1 {
                self.set(.warming)
            } else {
                self.set(.downloading(fraction: fraction))
            }
        }
        dictation.onInterim = { [weak self] text in self?.setInterim(text) }
        dictation.onFinalized = { [weak self] text in self?.appendFinalized(text) }
        dictation.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .warming: self.set(.warming)
            case .listening:
                // Said as soon as the model is loaded and the stream is open,
                // rather than held until a first result arrives: otherwise a
                // session nobody has spoken into yet is indistinguishable from one
                // still downloading, and resident weights look like a cold start.
                // Nothing is lost by saying it — `NemotronStreamingService` buffers
                // and replays chunks that arrive while the pipeline is still being
                // built, and the built-in recognizer finishes setup inside
                // `prepare`.
                self.set(.listening)
            case .idle: break   // the compile step decides what comes next
            }
        }
    }

    /// Whether a session is genuinely occupying the shared models.
    ///
    /// `.failed` is excluded: it is a short message, not work, and counting it
    /// would disable the Prompt tab and the Summary button for a workload that
    /// never started.
    var isRunning: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// Whether this session actually reached the shared Qwen host.
    ///
    /// `dismiss()` arms the release timer from it. Keyed on the work having
    /// happened rather than on the phase: a blocked or offline start also leaves a
    /// non-idle phase, and would schedule a release for a model nobody loaded.
    private var didTouchSharedModels = false

    private var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// The last un-finalized text, kept across the finish so it cannot be lost.
    private var lastInterim = ""

    /// Hotkey entry point. Starts a session, finishes the running one, or — while
    /// there is nothing yet to finish — abandons it.
    ///
    /// **Finishing requires an open microphone.** `finish()` commits — it awaits
    /// the start task, the drain, the repair and the insertion — so pressed
    /// before the recognizer is up it awaits a model *download* and the key looks
    /// inert for minutes, with nothing captured to commit anyway.
    ///
    /// `.warming` is therefore asked of the *session*, not the phase: the panel
    /// stays on "載入模型" until the first result arrives, so a short dictation
    /// ended before its first interim is still `.warming` with its only sentence
    /// in the decoder. That one has to drain.
    func toggle() {
        Self.log.info("hotkey toggle: phase=\(String(describing: self.phase), privacy: .public)")
        switch phase {
        case .idle, .failed:
            start()
        case .listening:
            finish()
        case .warming:
            if dictation.state == .listening { finish() } else { cancel() }
        case .downloading, .preparingModel:
            cancel()
        case .finishing:
            // A second press on a finish that has not landed abandons it. Without
            // this, a drain that never returns leaves the panel up with the hotkey
            // doing nothing.
            cancel()
        case .tidying, .compiling, .inserting:
            break   // model work or a paste in flight; ⎋ still cancels
        }
    }

    // MARK: - Lifecycle

    /// Abandon the session and keep nothing. Reached from ⎋ and from the panel's
    /// ✕; ⌃⌥Space is a toggle and commits instead.
    ///
    /// Works from every phase, including the ones `toggle()` ignores as "already
    /// committed" — cancelling is the one thing that should still be possible
    /// after committing, and a `Prompt` compile is tens of seconds of GPU work for
    /// a result the user may already have decided against.
    func cancel() {
        guard phase != .idle else { return }
        Self.log.info("cancelled at phase=\(String(describing: self.phase), privacy: .public)")
        // Microphone off in this turn — the recording indicator going out is how
        // the user knows ⎋ registered, and it must not wait on the drain.
        silenceWatchdog?.cancel()
        dictation.closeInput()
        // Whether anything is running that `dismiss()`ing early could get wrong.
        // Read before the phase is overwritten.
        let touchedSharedModels = didTouchSharedModels
        set(.finishing)
        // Chain onto the in-flight task rather than dropping it, as `finish()`
        // does. Reporting idle while a compile is still decoding lets a Summary
        // pressed straight afterwards `unload()` the Qwen container out from under
        // it — the `GPU.clearCache()` crash this whole file is arranged to prevent.
        let pending = work
        work = Task { [weak self] in
            pending?.cancel()
            if touchedSharedModels {
                // Unbounded: a live MLX generation is being awaited, and returning
                // early is exactly the crash above.
                await pending?.value
            } else {
                // Bounded: nothing has reached the GPU, and the task may be parked
                // inside a model download that does not honour cancellation.
                await Deadline.run(Self.cancelDrainLimit) { await pending?.value }
            }
            guard let self else { return }
            self.dictation.stop()
            // Said before the panel vanishes: one that just disappears is
            // indistinguishable from a crash, and the text is genuinely gone.
            self.flashFailure("已取消 Cancelled", seconds: 1.2)
        }
    }

    /// Longest a cancel waits for a not-yet-model-touching task to unwind.
    ///
    /// Generous enough for an ordinary `prepare` to notice cancellation and
    /// return, short enough that a wedged one is still an interruption rather
    /// than a hang.
    private static let cancelDrainLimit: Duration = .seconds(2)

    private func start() {
        transcript = ""
        interim = ""
        interimCount = 0
        installCancelKeys()
        // Show the panel BEFORE anything can fail: `flashFailure` only writes into
        // the HUD, so a blocked start would explain itself into a window that had
        // never been ordered in.
        hud.show(near: NSEvent.mouseLocation)
        if let blocker = blockedBy() {
            Self.log.info("start blocked: \(blocker, privacy: .public)")
            flashFailure(blocker)
            return
        }
        // Ask for the permission the result depends on before recording rather
        // than after. Recording starts either way — without it the text lands on
        // the clipboard instead of at the cursor, a degraded result rather than
        // none. `…Once` because the dialog reappears on every call while the
        // process still reads as untrusted.
        Permissions.requestAccessibilityOnce()
        // Claim the phase synchronously: `isRunning` false across the whole
        // `dictation.start` suspension lets a second consumer onto the shared
        // models during exactly the window when this one is loading them.
        set(.warming)
        work = Task { [weak self] in
            guard let self else { return }
            // Fail before asking for speech, not after. The compiler makes the
            // same check, but by then a paragraph has been dictated into a
            // pipeline that could never have produced anything.
            if self.settingsProvider().promptQuickInsertMode.needsLanguageModel,
               !self.qwenHost.isComplete, await !NetworkCheck.isOnline() {
                self.flashFailure("模型尚未下載且離線 Model not downloaded, offline")
                return
            }
            do {
                let language = PromptDictation.language(for: self.settingsProvider())
                Self.log.info("session start: language=\(language, privacy: .public)")
                try await self.dictation.start(language: language)
                // Read once the engine exists, so the joins below match how this
                // recognizer segments.
                self.segmentsCarryOwnSpacing =
                    self.dictation.segmentsCarryTheirOwnSpacing ?? false
                Self.log.notice("""
                    session listening, ownSpacing=\(self.segmentsCarryOwnSpacing, privacy: .public)
                    """)
                self.watchForSilentCapture()
            } catch is CancellationError {
                Self.log.info("session start cancelled")
            } catch {
                // A cancel that reached the engine surfaces here as whatever that
                // engine throws on unwind, and `cancel()` has already said "已取消".
                // Reporting it again would replace that with a raw framework
                // message and re-arm the timer on a panel already going away.
                guard !Task.isCancelled else {
                    Self.log.info("session start cancelled during load")
                    return
                }
                Self.log.error("session start failed: \(error.localizedDescription, privacy: .public)")
                self.flashFailure(error.localizedDescription)
            }
        }
    }

    /// Say so when a capture that started cleanly is delivering no audio.
    ///
    /// `router.enable(.microphone)` returning without throwing means the tap went
    /// on and the engine started; it does not mean buffers are arriving. Silence
    /// then looks exactly like a wedged hotkey.
    ///
    /// Only ever *adds* a message, and only in the phases where no word has been
    /// recognized: a session producing text is by definition receiving audio, and
    /// a finished one must not have its result replaced by a warning.
    private func watchForSilentCapture() {
        silenceWatchdog?.cancel()
        silenceWatchdog = Task { [weak self] in
            try? await Task.sleep(for: DictationSession.silentStartGrace)
            guard let self, !Task.isCancelled,
                  !self.dictation.isReceivingAudio,
                  self.phase == .warming || self.phase == .listening
            else { return }
            Self.log.notice("no audio after \(DictationSession.silentStartGrace, privacy: .public)")
            self.hud.update(
                phase: self.phase,
                text: "沒有收到麥克風聲音 No audio from the microphone — "
                    + "check the input device in System Settings → Sound",
                live: ""
            )
        }
    }

    /// Cancelled whenever the session ends, so it cannot fire over a later one.
    private var silenceWatchdog: Task<Void, Never>?

    private func finish() {
        silenceWatchdog?.cancel()
        // Close the microphone in this turn: the recording indicator going out is
        // how the user knows the key registered, and it must not wait on the
        // drain below.
        dictation.closeInput()
        // Keep the un-finalized text instead of discarding it. Unlike a meeting, a
        // dictation ends *while* the last utterance is still interim, and
        // `transcript` only accumulates finalized segments — so without this the
        // last sentence is lost. The drain below still gives the recognizer its
        // chance to finalize properly; this is the fallback for when it does not.
        lastInterim = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        interim = ""
        // Snapshotted in the same breath as the interim, so "did the drain
        // finalize anything?" is measured from exactly the moment it was set
        // aside.
        let transcriptBeforeDrain = transcript.count
        set(.finishing)
        // Chain onto the start task rather than replacing it: overwriting `work`
        // while it is suspended inside `dictation.start` orphans it, and on
        // resuming it re-installs `asr.onEvent` and reopens the microphone on a
        // session this controller believes is finished.
        let pending = work
        work = Task { [weak self] in
            pending?.cancel()
            await pending?.value
            guard let self else { return }
            // Read the transcript *after* the drain, never before: the sentence
            // being spoken when the key was pressed has not been decoded yet, and
            // a dictation is frequently only that sentence.
            await self.dictation.settle()
            guard !Task.isCancelled else {
                Self.log.info("finish cancelled during drain")
                self.dismiss()
                return
            }
            // The drain usually finalizes the utterance, and then appending the
            // interim duplicates the user's last sentence.
            // `DictationTranscriptAssembler` owns that decision and is tested on it.
            let drainProducedText = self.transcript.count > transcriptBeforeDrain
            let carried = self.lastInterim.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = DictationTranscriptAssembler.assemble(
                transcript: self.transcript,
                carriedInterim: carried,
                drainProducedText: drainProducedText,
                segmentsCarryOwnSpacing: self.segmentsCarryOwnSpacing)
            if !carried.isEmpty {
                Self.log.notice("""
                    interim \(carried.count, privacy: .public) chars: \
                    drained=\(drainProducedText, privacy: .public), \
                    kept=\(spoken.count > self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).count, privacy: .public)
                    """)
            }
            self.lastInterim = ""
            Self.log.info("""
                finish: captured \(spoken.count, privacy: .public) chars, interim=\(self.interimCount, privacy: .public), mode=\(self.settingsProvider().promptQuickInsertMode.rawValue, privacy: .public)
                """)
            guard !spoken.isEmpty else {
                Self.log.info("finish: nothing captured, dismissing")
                self.dismiss()
                return
            }
            await self.compileAndInsert(spoken)
        }
    }

    /// Repair the dictated transcript.
    ///
    /// One driver shared with the Prompt tab's 整理 button, so a mis-hearing is
    /// fixed once, in one place, with one set of safety checks.
    private func tidy(_ text: String) async -> TranscriptTidier.Report {
        let report = await tidier.tidy(
            text, origin: .speech, mergesSelfCorrections: true,
            onProgress: { [weak self] fraction in self?.set(.tidying(fraction: fraction)) }
        )
        // `notice`, not `info`: **`Logger.info` is not persisted to the log store
        // by default**, so `log show --predicate …` returns nothing for it, and
        // this is the one line worth reading when a tidy pass looks inert.
        Self.log.notice("""
            tidy in=\(text.count, privacy: .public) out=\(report.text.count, privacy: .public) \(report.summary, privacy: .public) [\(report.changes(from: text), privacy: .public)]
            """)
        return report
    }

    /// A one-line note when the repair did not do what the mode promises, or nil.
    ///
    /// A gate that silently rejected everything is indistinguishable from a model
    /// with nothing to fix, so every outcome gets words — including "found nothing
    /// to fix". Shown *after* the insert: the text landing is the important part
    /// and it should not wait on an explanation.
    private func tidyNote(_ report: TranscriptTidier.Report) -> String? {
        if report.modelSilent { return "模型無法使用，已插入原文 Model unavailable — raw text inserted" }
        if report.fallbacks.isEmpty, !report.changedAnything, report.passagesUnchanged > 0 {
            return "整理完成，沒有需要修改的地方 Nothing to fix"
        }
        guard !report.fallbacks.isEmpty else { return nil }
        let reason = PromptComposerViewModel.describe(report.fallbacks[0])
        return report.changedAnything
            ? "部分整理被安全檢查擋下（\(reason)）Partly tidied"
            : "整理被安全檢查擋下（\(reason)），已插入原文 Kept as dictated"
    }

    private func compileAndInsert(_ spoken: String) async {
        let settings = settingsProvider()
        // Every mode but `Raw` runs a Qwen pass from here, so this is the one
        // place the shared host can be reached.
        didTouchSharedModels = settings.promptQuickInsertMode.needsLanguageModel
        let text: String
        /// Something to say once the text has landed, or nil.
        var note: String?

        switch settings.promptQuickInsertMode {
        case .rawTranscript:
            // Verbatim, including hesitations: this is the mode that answers "what
            // did the recognizer actually hear?", which is the question asked when
            // Tidied gets a term wrong. The layer that removes an "um" is the same
            // layer that can remove a word the user chose, so nothing runs here.
            text = spoken
        case .tidiedTranscript:
            // The repair pass and nothing else: the sentences the user said,
            // spelled correctly, self-corrections merged, structure preserved.
            //
            // The cleaner still runs: hesitations are acoustic artifacts rather
            // than words, and removing them deterministically before the model
            // sees them is cheaper and safer than asking it to.
            let report = await tidy(cleaner.cleanup(spoken, origin: .speech))
            guard !Task.isCancelled else { dismiss(); return }
            text = report.text
            note = tidyNote(report)
        case .compiledPrompt:
            // Repair before compiling, as the Prompt tab does. Dictation is
            // precisely where mis-heard terms come from, and a mangled identifier
            // survives compilation and lands in the editor looking deliberate.
            let cleaned = await tidy(cleaner.cleanup(spoken, origin: .speech)).text
            set(.compiling(tokens: 0))
            let result = await compiler.compile(
                request: cleaned,
                language: settings.promptOutputLanguage,
                rulebook: rulebookProvider(),
                symbolMode: settings.promptSymbolMode,
                onDownload: { [weak self] fraction in
                    Task { @MainActor in
                        self?.set(.compiling(tokens: 0))
                        self?.hud.update(phase: .warming, text: "下載模型 \(Int(fraction * 100))%")
                    }
                },
                onProgress: { [weak self] produced in
                    Task { @MainActor in
                        guard let self, case .compiling = self.phase else { return }
                        self.set(.compiling(tokens: produced))
                    }
                },
                prepareModel: preparingModelOnHUD
            )
            guard !Task.isCancelled else { dismiss(); return }
            // A compile that cannot run is a reason to hand the transcript back,
            // not to lose it.
            if case let .modelUnavailable(reason) = result.outcome {
                rescue(cleaned, reason: reason)
                return
            }
            // `autoFix`, not just `optimize`: the tab applies the mechanical
            // lint fixes during compile, and a prompt inserted at the cursor has
            // even less chance of being reviewed first.
            let optimized = PromptOptimizer.autoFix(
                PromptOptimizer.optimize(
                    result.ir,
                    repoRoot: settings.promptTargetProjectPath,
                    request: cleaned
                )
            ).ir
            let synced = settings.promptTargetProjectPath.map {
                PromptArtifactWriter.allSyncedSymbols(inProjectAt: $0)
            } ?? []
            text = PromptRenderer.render(
                optimized,
                options: PromptRenderOptions(
                    kind: .prompt,
                    language: settings.promptOutputLanguage,
                    symbolMode: settings.promptSymbolMode,
                    rulebook: rulebookProvider(),
                    syncedSymbols: synced,
                    layout: settings.promptLayout,
                    detail: settings.promptDetailLevel
                )
            ).content
        }

        // Empty output from a non-empty dictation is a pipeline failure, not an
        // empty dictation — `finish()` has already returned early when nothing was
        // heard — so the words are handed back rather than dropped.
        guard !text.isEmpty else {
            rescue(spoken, reason: "整理後沒有內容 The pass produced nothing")
            return
        }

        set(.inserting)
        // **Nothing is copied before the insert**, and that ordering is
        // load-bearing: `CursorTextInserter` snapshots the pasteboard on entry to
        // restore it afterwards, so copying first would make that snapshot our own
        // text and keep it on the clipboard after every successful insert.
        Self.log.info("""
            inserting \(text.count, privacy: .public) chars, \
            accessibility=\(Permissions.accessibilityAuthorized, privacy: .public)
            """)
        do {
            try await CursorTextInserter.insert(text)
            // **And onto the clipboard, after the insert.** `insert` restores the
            // user's own clipboard on its way out, so this has to come afterwards
            // to win. Both, deliberately: the cursor is not always where it should
            // have gone, and a transcript cannot be reproduced — it was spoken.
            let copied = Self.copyToPasteboard(text)
            Self.log.notice("insert ok, copied=\(copied, privacy: .public)")
            // Only once the text is in is there room to say the repair was
            // skipped; before it, the note delays what the key was pressed for.
            if let note { flashFailure(note) } else { dismiss() }
        } catch CursorTextInserter.InsertError.notTrusted {
            Self.log.error("insert refused: accessibility not granted")
            // This branch throws before the inserter touches the pasteboard, so
            // the copy has to happen here. **Verified**, because the message below
            // promises it: `setString` can be refused, and saying the words are
            // safe on the clipboard when they are not loses the whole dictation.
            let copied = Self.copyToPasteboard(text)
            // The pane is offered, not opened. This runs at the end of a dictation
            // started from another application: the user pressed a key to get text
            // at their cursor, and answering with System Settings in front of
            // whatever they were working in is a hijack even now that something has
            // gone wrong. `requestAccessibilityOnce` cannot help either — macOS
            // stops showing the dialog once a denial is recorded — so a button is
            // the only honest offer. The text is on the pasteboard either way.
            //
            // Long enough to press: a 2.5-second panel is not a button.
            flashFailure(
                (copied ? "已複製到剪貼簿 Copied · " : "無法複製到剪貼簿 Clipboard unavailable · ")
                    + Permissions.accessibilityHint,
                seconds: 8
            )
        } catch {
            // The inserter restores the user's pasteboard on its own error paths
            // before rethrowing, so the transcript is not on it here either.
            let copied = Self.copyToPasteboard(text)
            flashFailure(copied
                ? "已複製到剪貼簿 Copied to clipboard"
                : "插入與複製都失敗 Insert and clipboard both failed")
            Self.log.error("""
                cursor insert failed: \(error.localizedDescription, privacy: .public), \
                copied=\(copied, privacy: .public)
                """)
        }
    }

    /// Hand the words back when the pipeline after recognition cannot deliver
    /// them to the cursor.
    ///
    /// The transcript cannot be re-said, so every failure downstream of it — a
    /// model that will not load, a repair that returns nothing, a render that
    /// produces an empty prompt — gives the words back rather than closing the
    /// panel with nothing anywhere. Verified, and reported honestly either way.
    private func rescue(_ text: String, reason: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { flashFailure(reason); return }
        let copied = Self.copyToPasteboard(trimmed)
        Self.log.notice("""
            rescued \(trimmed.count, privacy: .public) chars to the clipboard: \
            copied=\(copied, privacy: .public), reason=\(reason, privacy: .public)
            """)
        flashFailure(
            copied ? "\(reason)．逐字稿已複製到剪貼簿 Transcript copied"
                   : "\(reason)．且無法複製到剪貼簿 Clipboard also unavailable",
            seconds: 4
        )
    }

    /// Put `text` on the pasteboard and confirm it is there.
    ///
    /// Both halves matter: `setString` reports whether the write was accepted,
    /// reading it back reports whether what came out is what went in. Callers turn
    /// the answer into the difference between "one ⌘V away" and "gone".
    static func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        return pasteboard.string(forType: .string) == text
    }

    /// Cancel everything and release the shared models' claim. Called before a
    /// meeting starts.
    func cancelAndDrain() async {
        // Cancel and drain BEFORE stopping the session: stopping first leaves the
        // awaited start task free to finish and re-open everything `stop()` just
        // closed, coming back `.listening` with no UI left to turn it off.
        let pending = work
        pending?.cancel()
        if didTouchSharedModels {
            await pending?.value
        } else {
            // Bounded for the same reason `cancel()` is: a meeting's Start awaits
            // this, and a session parked in a download that ignores cancellation
            // would block it for the length of that download.
            await Deadline.run(Self.cancelDrainLimit) { await pending?.value }
        }
        work = nil
        dictation.stop()
        dismiss()
    }

    // MARK: - State plumbing

    /// Everything the recognizer produces passes through here.
    ///
    /// The app writes Traditional Chinese or English and nothing else, but the
    /// mixed-language build (the dictation default) emits Simplified for Mandarin.
    /// Normalizing at the point of entry covers every mode including `Raw`, which
    /// stays verbatim in *words* — this changes how a character is written, never
    /// which word it is.
    private static func normalized(_ text: String) -> String {
        TraditionalChineseGuard.normalizingScript(text)
    }

    /// How many interim revisions arrived this session. Counted rather than
    /// logged per event — they arrive several times a second, and the only
    /// question is whether streaming revision reaches this flow at all.
    private var interimCount = 0

    /// The recognizer has produced something, so it is genuinely running.
    private func confirmListening() {
        guard phase == .warming else { return }
        set(.listening)
    }

    private func setInterim(_ text: String) {
        interimCount += 1
        confirmListening()
        interim = Self.normalized(text)
        hud.update(phase: phase, text: displayText, live: interim)
    }

    private func appendFinalized(_ text: String) {
        interim = ""
        let text = Self.normalized(text)
        confirmListening()
        Self.log.info("finalized segment: \(text.count, privacy: .public) chars")
        transcript = joined(transcript, text)
        hud.update(phase: phase, text: displayText, live: interim)
    }

    private var displayText: String { joined(transcript, interim) }

    /// Join two recognizer segments, the way the running engine needs them joined.
    ///
    /// **The engine decides, not a guess about the characters.** The session
    /// forwards segments untrimmed and `segmentsCarryTheirOwnSpacing` says whether
    /// they already contain the join: Apple's progressive segments do, Nemotron's
    /// whole utterances do not.
    private func joined(_ left: String, _ right: String) -> String {
        DictationTranscriptAssembler.join(
            left, right, segmentsCarryOwnSpacing: segmentsCarryOwnSpacing)
    }

    /// The running engine's answer, remembered so it survives the engine being
    /// released before the last join.
    private var segmentsCarryOwnSpacing = false

    private func set(_ next: Phase) {
        phase = next
        hud.update(phase: next, text: displayText, live: interim)
    }

    private func dismiss() {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        lastInterim = ""
        phase = .idle
        if didTouchSharedModels {
            didTouchSharedModels = false
            didFinishWork()
        }
        transcript = ""
        interim = ""
        releaseCancelKeys()
        hud.hide()
    }

    /// Say why it stopped, then close.
    ///
    private func flashFailure(_ message: String, seconds: Double = 2.5) {
        set(.failed(message))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, case .failed = self.phase else { return }
            self.dismiss()
        }
    }

    // MARK: - Escape

    /// The name ⎋ is registered under for the length of a session.
    private static let cancelHotkeyName = "prompt.dictation.cancel"

    /// Claim ⎋ for the length of this session.
    ///
    /// **A Carbon hot key, because it is the only path that needs no permission.**
    /// ⎋ has to work while the user is in *another* application — that is what the
    /// dictation hotkey is for — and an `NSEvent` monitor cannot serve there: a
    /// local one only receives events routed to this app, and the HUD is a
    /// `.nonactivatingPanel` that never takes focus. `RegisterEventHotKey` is
    /// dispatched by the window server, so it is indifferent to which application
    /// is in front and to which display anything is on. It is how ⌃⌥Space works.
    ///
    /// The cost is that ⎋ does not reach the frontmost application while it is
    /// registered. That is bounded by the session — seconds, during which the user
    /// is speaking rather than typing — and it is given back in
    /// `releaseCancelKeys`. The panel's ✕ covers the case where the registration
    /// is refused because another process already owns the key.
    private func installCancelKeys() {
        GlobalHotKeyCenter.shared.register(
            Self.cancelHotkeyName, keyCode: kVK_Escape, modifiers: 0
        ) { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    /// Give ⎋ back to the system. Reached from `dismiss()`, which every ending
    /// runs through.
    private func releaseCancelKeys() {
        GlobalHotKeyCenter.shared.unregister(Self.cancelHotkeyName)
    }

}
