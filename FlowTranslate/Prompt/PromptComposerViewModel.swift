import Foundation
import FlowTranslateCore

/// Drives the Prompt tab: capture a request (spoken or typed), compile it into a
/// `PromptIR`, and render it for whichever Claude Code surface the user wants.
///
/// **Shares models, never duplicates them.** The ASR service and the Qwen host
/// are the same instances the meeting uses, so this feature adds no resident
/// model memory on a 16 GB machine. What makes that safe is hard mutual
/// exclusion: compiling and recording are both blocked while a meeting is
/// running, and `cancelAndDrain()` lets the meeting reclaim the GPU before it
/// starts. On Apple silicon the ANE and GPU share one memory bus, so a 4B decode
/// running alongside live captions would show up as caption latency jitter — a
/// low-priority queue is not good enough here.
///
/// Dictation captures through the **same `AudioRouter` a meeting uses**, so the
/// microphone gets the same fixed gain, auto-gain and soft limiter the meeting
/// path applies. See `DictationSession.router`: the earlier private-`MicCapture`
/// arrangement meant the same voice arrived quieter and unprocessed, which is
/// precisely what the voice-activity gate drops and the acoustic model mishears.
@MainActor
final class PromptComposerViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// ASR weights are loading. Shown honestly rather than pretending to listen.
        case warming
        case listening
        /// Input closed, waiting out the drain for the sentence still decoding.
        ///
        /// Its own case rather than borrowing `listening`, for the same reason
        /// `QuickDictationController` gives: the Dictate button decides what a
        /// click does from the phase, so leaving it on `listening` let a second
        /// click start a second drain over the same session and reassign `work`
        /// out from under the first one's tidy pass.
        case finishing
        /// Repairing the dictated transcript before it is shown for review.
        case tidying(fraction: Double)
        /// Compiling, with the number of tokens produced so far.
        case compiling(tokens: Int)

        var isBusy: Bool { self != .idle }
    }

    // MARK: - Published state

    /// The request. Filled by dictation, typing, or both.
    @Published var inputText: String = ""
    @Published private(set) var origin: PromptInputOrigin = .typed
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var interimText: String = ""
    @Published private(set) var ir: PromptIR?
    @Published private(set) var findings: [LintFinding] = []
    @Published private(set) var artifact: PromptArtifact?
    @Published private(set) var comparison: TokenComparison?
    @Published private(set) var statusMessage: String = ""
    /// Bumped on every rulebook mutation, so anything caching a *render* of the
    /// book can key on it.
    ///
    /// A structural key — rule count, language, symbol names — cannot do that
    /// job: editing a rule's description or its expansion changes none of those,
    /// so the cost readout would report the pre-edit file for the rest of the
    /// session.
    private var rulebookRevision = 0

    @Published var rulebook: PromptRulebook {
        // Debounced: the editor binds text fields straight to rule properties,
        // so this fires on every keystroke, and both halves are expensive —
        // `save` encodes the whole rulebook, `render` runs the compressor's
        // several `NLTagger` passes over every section. Doing that per character
        // on the main thread made typing a rule description visibly lag.
        //
        // Re-rendering at all is not optional: the artifact is a function of the
        // rulebook, and saving without re-rendering left the preview showing the
        // old expansion while the cost readout showed the new one.
        didSet {
            rulebookRevision += 1
            scheduleRulebookCommit()
        }
    }

    // MARK: - Collaborators

    private let dictation: DictationSession
    private let compiler: QwenPromptCompiler
    /// Repairs the request before it reaches the compiler — mis-hearings when it
    /// was dictated, typos when it was typed. Not `QwenCorrector`: that one's
    /// prompt asserts the text came from a speech recognizer, which makes it
    /// hunt for homophone errors in text somebody typed.
    private let repairer: PromptTextRepairer
    /// Drives the repair. Shared with the ⌃⌥Space hotkey so both behave alike.
    private var tidier: TranscriptTidier {
        TranscriptTidier(repairer: repairer, prepareModel: prepareModel)
    }
    private let cleaner = SpokenNoiseCleaner()
    /// Whether something else currently owns the shared models — a meeting, a
    /// summary, a bulk download, or the dictation hotkey. The composer only
    /// reads this; it never mutates the state behind it.
    /// Names what is holding the shared models, or nil when nothing is.
    private let blockedBy: @MainActor () -> String?
    /// Signals that the shared models are no longer needed, so the owner can
    /// schedule their release.
    private let didFinishWork: @MainActor () -> Void
    /// Loads the shared model through the owner, inheriting its failure budget,
    /// its single load task and its wait on the at-Start prefetch.
    private let prepareModel: (@MainActor () async -> String?)?

    /// Read live from the owner rather than held as a snapshot.
    ///
    /// A copy only stays correct while every mutation remembers to push it here,
    /// and one did not: `applySettings()` was made conditional to keep the lazy
    /// composer from being built at launch, which meant a settings change before
    /// the tab was first opened never arrived. Reading through a closure makes
    /// staleness structurally impossible instead of a rule to remember.
    private let settingsProvider: @MainActor () -> CaptionSettings
    private var settings: CaptionSettings { settingsProvider() }
    /// Whatever model work is in flight — tidying or compiling. One handle so
    /// `cancelAndDrain` can never miss a generation.
    private var work: Task<Void, Never>?
    /// Debounces saving and re-rendering while the rulebook is being edited.
    private var rulebookCommit: Task<Void, Never>?
    /// The in-flight exact-token-count refresh. Holds the shared container.
    private var countRefinement: Task<Void, Never>?
    /// The Qwen tokenizer's answers, populated after each render.
    private let tokenCounter = QwenTokenCounter()
    private let qwenHost: QwenModelHost
    /// Counts with the real tokenizer when it has an answer, the character
    /// heuristic otherwise — and reports which it used.
    private var meter: TokenMeter { TokenMeter(counter: tokenCounter) }

    init(
        asr: NemotronStreamingService,
        router: AudioRouter,
        qwenHost: QwenModelHost,
        settings: @escaping @MainActor () -> CaptionSettings,
        blockedBy: @escaping @MainActor () -> String?,
        didFinishWork: @escaping @MainActor () -> Void = {},
        prepareModel: (@MainActor () async -> String?)? = nil
    ) {
        self.prepareModel = prepareModel
        // The engine is chosen per session, not per launch: the factory reads
        // the setting each time `start` runs, so switching it in Settings takes
        // effect on the next dictation.
        self.dictation = DictationSession(router: router) { [settings] in
            DictationEngineFactory.make(
                for: settings(), asr: asr, tier: PromptDictation.tier
            )
        }
        self.compiler = QwenPromptCompiler(host: qwenHost)
        self.repairer = PromptTextRepairer(host: qwenHost)
        self.qwenHost = qwenHost
        self.settingsProvider = settings
        self.blockedBy = blockedBy
        self.didFinishWork = didFinishWork
        self.rulebook = RulebookStore.load()

        // Same script normalization as the hotkey flow: the recognizer's
        // mixed-language build writes Mandarin in Simplified, and this app's
        // input is Traditional Chinese or English. Only the script changes.
        dictation.onInterim = { [weak self] text in
            self?.interimText = TraditionalChineseGuard.normalizingScript(text)
        }
        dictation.onFinalized = { [weak self] text in
            self?.interimText = ""
            self?.append(dictated: TraditionalChineseGuard.normalizingScript(text))
        }
        dictation.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            // The ASR owns the dictation phases and nothing else. `.finishing`,
            // `.tidying` and `.compiling` belong to whichever task claimed them —
            // and stopping dictation is exactly when finishing and tidying start,
            // so treating `.idle` from the recognizer as "nothing is happening"
            // reopened every button in the middle of a generation.
            case .idle: if self.phase == .warming || self.phase == .listening {
                self.phase = .idle
            }
            case .warming: self.phase = .warming
            case .listening: self.phase = .listening
            }
        }
    }

    // MARK: - Availability

    /// Typing is always allowed — the exclusion is about the GPU, not the
    /// keyboard, so a user can draft during a meeting and compile afterwards.
    var canRecord: Bool { blockedBy() == nil && phase == .idle }
    var canCompile: Bool { blockedBy() == nil && phase == .idle && !inputText.trimmed.isEmpty }
    var isBusy: Bool { phase.isBusy }

    var blockedReason: String? {
        blockedBy().map { "\($0)，請先停止 stop it first" }
    }

    /// Re-render after a settings change. The values themselves are read live;
    /// this only decides whether the change is worth the render cost.
    func apply(previous: CaptionSettings) {
        let settings = self.settings
        // Pointing at a different project means a different set of resolvable
        // symbols. This is one of only two ways that answer can change.
        if previous.promptTargetProjectPath != settings.promptTargetProjectPath {
            invalidateSyncedSymbols()
        }
        // `applySettings` fires on every settings mutation, including a gain
        // slider tick and a font step. Re-rendering unconditionally ran two full
        // `PromptRenderer.render` passes — several `NLTagger` passes per section
        // — plus a tokenizer task, on the MainActor, for changes that cannot
        // affect the prompt.
        guard Self.affectsPrompt(previous, settings) else { return }

        // Changing the output language needs a new compile, not a re-render.
        // The rulebook expansions follow the setting immediately, but the goal
        // and context are prose the model wrote in the language selected at the
        // time — so a re-render produced a Chinese constraint under an English
        // task, which reads as the switch half-working rather than as the
        // limitation it is. Only another model call can restate them.
        if previous.promptOutputLanguage != settings.promptOutputLanguage,
           ir != nil, !inputText.trimmed.isEmpty {
            guard canCompile else {
                // Busy, or the model is unavailable. Re-rendering still switches
                // the tags and the rulebook wording, so saying nothing would
                // leave a half-translated prompt looking like the setting only
                // works on some sections.
                render()
                statusMessage = "已切換輸出語言，但現在無法重新編譯"
                    + (blockedReason.map { "（\($0)）" } ?? "")
                    + "，需求內容仍是上一次編譯的語言。"
                    + " Switched, but the body needs another compile."
                return
            }
            compile()
            return
        }
        render()
    }

    /// Whether a settings change can alter the rendered prompt.
    static func affectsPrompt(_ before: CaptionSettings, _ after: CaptionSettings) -> Bool {
        before.promptOutputLanguage != after.promptOutputLanguage
            || before.promptSymbolMode != after.promptSymbolMode
            || before.promptLayout != after.promptLayout
            || before.promptDetailLevel != after.promptDetailLevel
            || before.promptTargetProjectPath != after.promptTargetProjectPath
            || before.promptRuleCategories != after.promptRuleCategories
    }

    /// Marks that the user typed. Dictation flips this back to `.mixed` when it
    /// appends to text that was already edited by hand.
    func noteManualEdit() {
        switch origin {
        case .typed: break
        case .speech, .mixed: origin = .mixed
        }
    }

    // MARK: - Dictation

    func startDictation() async {
        guard canRecord else { return }
        statusMessage = ""
        interimText = ""
        do {
            // The tier travels with the engine now (see `DictationEngineFactory`),
            // and it is `PromptDictation.tier` for both entry points rather than
            // the caption tier. Reading `settings.asrTier` here meant the tab and
            // the hotkey loaded two different ~600 MB variants of the same model,
            // and `prewarmDictationASR` warmed the one the tab did not use.
            try await dictation.start(language: dictationLanguage)
        } catch {
            phase = .idle
            statusMessage = error.localizedDescription
        }
    }

    /// Stop dictating and hand the transcript to the repair pass.
    ///
    /// `settle()`, not `stop()`. The two differ by one thing that decides whether
    /// the feature works: `stop()` closes the input **and** gives back
    /// `asr.onEvent` in the same turn, but the pipeline still runs one last
    /// `finalizeUtterance` for the audio it already took in — the sentence being
    /// spoken when the button was pressed — and that lands ~600 ms later, on a
    /// handler that now belongs to the meeting view model, which drops it because
    /// no meeting is running. The sentence vanished with nothing said, and a short
    /// dictation is frequently only that sentence.
    ///
    /// The microphone still closes in this turn (`closeInput`, inside `settle`),
    /// because the recording indicator going out is how the user knows the click
    /// registered; only the handover waits.
    ///
    /// The un-finalized text is kept as a fallback for the same reason
    /// `QuickDictationController.finish` keeps it: the drain finalizes the
    /// utterance in almost every case, and when it does not, the words the user
    /// watched appear are the ones they would otherwise lose.
    func stopDictation() async {
        guard phase == .listening || phase == .warming else { return }
        let pending = interimText.trimmingCharacters(in: .whitespacesAndNewlines)
        interimText = ""
        phase = .finishing
        await dictation.settle()
        // Only when the drain produced nothing for it. Appending unconditionally
        // would duplicate the sentence the finalize just delivered.
        if !pending.isEmpty, !inputText.contains(pending) { append(dictated: pending) }
        // The drain can deliver one more partial before it stops, and nothing
        // downstream clears it — the live line would sit under the request box
        // for the whole tidy pass.
        interimText = ""
        // Not routed through `tidy()`: the ASR has not necessarily reported
        // `.idle` yet, so `canCompile` may still be false. Nothing else can be
        // running here — the dictation session held the microphone.
        beginTidy()
    }

    /// Start a repair pass from the Tidy button.
    func tidy() {
        guard canCompile else { return }
        beginTidy()
    }

    /// Claims the phase synchronously, then starts the work.
    ///
    /// Mirrors `compile()`: taking the phase before creating the task closes the
    /// window where a second tap still passed `canCompile`, overwrote `work` and
    /// orphaned the first pass into an untracked generation that
    /// `cancelAndDrain` could no longer wait for.
    private func beginTidy() {
        phase = .tidying(fraction: 0)
        statusMessage = ""
        work = Task { [weak self] in await self?.tidyTranscript() }
    }

    /// Repair the request, then hand it back for review.
    ///
    /// Runs for typed input as well as dictated. Only the *filler removal* step
    /// is voice-specific — a typed "嗯" is deliberate and a pasted snippet may
    /// contain anything — while typos, mangled technical terms and missing
    /// punctuation are not, and text that arrived by keyboard has no less claim
    /// on being fixed. Withholding repair from typed input was an oversight, not
    /// a policy: the button was wired up and silently returned.
    ///
    /// Split out from compiling on purpose. Asking one 4B model to fix errors
    /// *and* restructure *and* translate *and* emit strict JSON in a single pass
    /// is what made the earlier output poor; each pass alone is well within what
    /// the model does reliably.
    func tidyTranscript() async {
        let raw = inputText.trimmed
        guard !raw.isEmpty else { phase = .idle; return }

        // `cleanup` is itself origin-aware and returns typed text untouched, so
        // it is safe to call unconditionally.
        let cleaned = cleaner.cleanup(raw, origin: origin)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .idle; return
        }

        phase = .tidying(fraction: 0)
        statusMessage = ""

        // One generation over the whole request, not one per sentence. Shared
        // driver with the ⌃⌥Space hotkey, so a mis-hearing is fixed once, in one
        // place, with one set of safety checks.
        let report = await tidier.tidy(
            cleaned, origin: origin, mergesSelfCorrections: true,
            onProgress: { [weak self] fraction in
                guard let self, case .tidying = self.phase else { return }
                self.phase = .tidying(fraction: fraction)
            }
        )

        guard !Task.isCancelled else { phase = .idle; didFinishWork(); return }
        // Do not overwrite what the user has typed since. Tidy runs for seconds, and the field stays editable
        // throughout on purpose — the exclusion here is about the GPU, not the
        // keyboard. Writing the pass's own snapshot back regardless would delete
        // whatever was added while it ran, which is the one outcome a "tidy up my
        // text" button must never have.
        guard inputText.trimmed == raw else {
            statusMessage = "整理完成，但你在期間改過內容，已保留你的版本。"
                + " Kept your edits — tidy discarded its own result."
            phase = .idle
            didFinishWork()
            return
        }
        inputText = report.text
        statusMessage = Self.tidySummary(report)
        phase = .idle
        didFinishWork()
    }

    /// Say what happened — every outcome, including "nothing to fix".
    ///
    /// Finishing in silence makes "it doesn't actually fix anything"
    /// indistinguishable from "there was nothing to fix", and lets a gate quietly
    /// rejecting every repair go unnoticed. The passage gate has a dozen rules and
    /// every one of them is silent on its own.
    static func tidySummary(_ report: TranscriptTidier.Report) -> String {
        if report.modelSilent { return "模型無法使用，內容保持原樣 Model unavailable" }

        var parts: [String] = []
        if report.passagesRepaired > 0 || report.sentencesRepaired > 0 {
            parts.append("整理完成")
        }
        if !report.fallbacks.isEmpty {
            // Name what the safety gate threw away. Without this, a gate
            // rejecting everything looks exactly like a model with nothing to fix.
            let detail = Dictionary(grouping: report.fallbacks, by: { $0 })
                .map { "\(describe($0.key))×\($0.value.count)" }
                .sorted()
                .joined(separator: "、")
            parts.append("\(report.fallbacks.count) 段整段修正被安全檢查擋下（\(detail)），已改用逐句修正")
        }
        if report.sentencesRepaired > 0 {
            parts.append("逐句修正了 \(report.sentencesRepaired) 句")
        }
        if !report.sentenceRejections.isEmpty {
            parts.append("另有 \(report.sentenceRejections.count) 句的修正被擋下")
        }
        if parts.isEmpty { parts.append("模型判斷沒有明顯錯誤") }
        return parts.joined(separator: "；")
    }

    /// Plain-language reason, so the message says what to do about it.
    static func describe(_ rejection: PassageRepairGate.Rejection) -> String {
        switch rejection {
        case .empty: return "回了空白"
        case .unchanged: return "沒有變化"
        case .meta: return "模型在說明而非修正"
        case .simplifiedChinese: return "輸出成簡體"
        case .lengthRatio: return "長度變化過大"
        case .numberInvented: return "憑空多出數字"
        case .numbersDropped: return "刪掉太多數字"
        case .identifierInvented: return "憑空多出識別字"
        case .identifiersDropped: return "刪掉太多識別字"
        case .negationLost: return "把否定改成了肯定"
        case .contentAdded: return "多寫了內容"
        case .looped: return "輸出開始重複"
        case .truncated: return "輸出被長度上限截斷"
        case .tooDifferent: return "改動幅度過大"
        }
    }

    private func append(dictated text: String) {
        origin = inputText.trimmed.isEmpty ? .speech : (origin == .typed ? .mixed : origin)
        if inputText.trimmed.isEmpty {
            inputText = text
        } else {
            inputText += inputText.hasSuffix(" ") ? text : " \(text)"
        }
    }

    /// Which locale the dictation session runs in.
    ///
    /// Defaults to following the meeting language, which costs nothing. `auto`
    /// handles code-switching but uses the multilingual ship — free when the
    /// meeting language is already non-Latin, an extra variant download when it
    /// is English.
    private var dictationLanguage: String {
        PromptDictation.language(for: settings)
    }

    // MARK: - Compiling

    func compile() {
        guard canCompile else { return }
        // Claim the phase SYNCHRONOUSLY, before creating the task. Setting it
        // inside the task body left a window where a second tap still passed
        // `canCompile`, overwrote `compileTask`, and orphaned the first
        // generation — which then ran to completion untracked, so
        // `cancelAndDrain` could not wait for it.
        phase = .compiling(tokens: 0)
        statusMessage = ""
        work = Task { [weak self] in await self?.runCompile() }
    }

    private func runCompile() async {
        let request = inputText
        // Only speech carries hesitation sounds. Running the spoken cleaner over
        // typed text could eat a deliberate "嗯" or part of a pasted snippet.
        let cleaned = cleaner.cleanup(request, origin: origin)

        let result = await compiler.compile(
            request: cleaned,
            language: settings.promptOutputLanguage,
            rulebook: activeRulebook,
            onDownload: { [weak self] fraction in
                Task { @MainActor in
                    self?.statusMessage = "下載 Qwen 模型… \(Int(fraction * 100))%"
                }
            },
            onProgress: { [weak self] produced in
                Task { @MainActor in
                    guard let self, case .compiling = self.phase else { return }
                    self.phase = .compiling(tokens: produced)
                }
            },
            prepareModel: prepareModel
        )

        guard !Task.isCancelled else {
            phase = .idle
            // Even a cancelled compile may have loaded the model, so the release
            // still has to be armed. Without this, cancelling left ~2.3 GB
            // resident until the next meeting or the next compile.
            didFinishWork()
            return
        }

        let optimized = PromptOptimizer.optimize(
            result.ir,
            repoRoot: settings.promptTargetProjectPath,
            // The request itself, so a path the model copied out of its own
            // few-shot examples cannot reach the `<files>` section.
            request: cleaned
        )
        // Apply the mechanical fixes rather than listing them. Every one of
        // these is a known anti-pattern with a single correct resolution —
        // stripping "please double-check", which Anthropic's own Opus 5 guide
        // says causes over-verification, is not a decision worth interrupting
        // for. Compile should hand back a finished prompt.
        //
        // What survives is only what needs a human: contradictory constraints,
        // where the tool cannot know which one you meant.
        let (repaired, remaining) = PromptOptimizer.autoFix(optimized)
        ir = repaired
        findings = remaining
        switch result.outcome {
        case .compiled:
            // The one thing a successful compile can still get wrong. The
            // language rule is an instruction to the model, and a 4B model given
            // a Chinese request and told to write English often keeps writing
            // Chinese — leaving English tags around a Chinese task. Say so
            // rather than silently handing it over; re-compiling usually fixes
            // it, and translating it here would be an unguarded second pass over
            // text about to be sent to an agent.
            statusMessage = PromptLanguageCheck.mismatches(
                repaired, expected: settings.promptOutputLanguage
            )
                ? "模型沒有照設定的輸出語言寫（\(settings.promptOutputLanguage.displayName)），"
                    + "內容語言與標籤不一致。再編譯一次通常就會照做。"
                    + " The model did not write in the selected output language."
                : ""
        case .salvaged:
            statusMessage = "模型輸出無法解析，已從原文重建骨架 Model output could not be parsed"
        case .recovered:
            // Not a failure any more, so it does not read as one. The structure
            // survived; one bullet at the end may not.
            statusMessage = "需求很長，模型輸出在最後被長度上限截斷 —— 已保留產生完成的部分，"
                + "最後一項可能缺漏，請檢查一下。"
                + " Output hit the length cap; everything written before the cut was kept."
        case .truncated:
            // Names the actual cause and the actual fix. Reporting this as
            // "unparseable output" sent the user looking for a model problem
            // when the limit was one this code set.
            statusMessage = "需求太長，模型輸出被長度上限截斷且無法救回，已從原文重建骨架。"
                + "把需求拆成兩次編譯可得到完整結構。"
                + " Output hit the length cap — split the request in two."
        case let .modelUnavailable(reason):
            statusMessage = "模型無法使用：\(reason)"
        }
        render(baseline: cleaned)
        phase = .idle
        didFinishWork()
    }

    /// Cancel any in-flight compile and wait for it to finish.
    ///
    /// The meeting must call this before it loads models: unloading the Qwen
    /// container while a generation is running is the known `GPU.clearCache()`
    /// crash, so "cancelled" is not enough — the task has to be awaited.
    func cancelAndDrain() async {
        // Stop the microphone WITHOUT going through `stopDictation()`. That one
        // begins a tidy pass, which reassigns `work` — so the compile task this
        // function exists to await was replaced by a brand-new generation and
        // dropped untracked, leaving it running on the GPU for the caller to
        // unload the container out from under. Draining is the whole point of
        // this function; starting new work in it defeated it, and it also ran an
        // unwanted tidy over the user's draft on every `releaseQwen()`.
        // Drain first, then stop: a start task still suspended in
        // `dictation.start` would otherwise resume after the stop and reopen the
        // microphone on a session this object believes is finished.
        work?.cancel()
        await work?.value
        work = nil
        dictation.stop()
        interimText = ""
        countRefinement?.cancel()
        await countRefinement?.value
        countRefinement = nil
        phase = .idle
    }

    // MARK: - Rendering

    func applyAutoFixes() {
        guard let current = ir else { return }
        let fixable = findings.filter(\.isAutoFixable)
        guard !fixable.isEmpty else { return }
        let fixed = PromptOptimizer.apply(fixable, to: current)
        ir = fixed
        findings = PromptOptimizer.lint(fixed)
        render()
    }

    func apply(_ finding: LintFinding) {
        guard let current = ir, finding.isAutoFixable else { return }
        let fixed = PromptOptimizer.apply([finding], to: current)
        ir = fixed
        findings = PromptOptimizer.lint(fixed)
        render()
    }

    /// Re-render the current IR for the selected agent and re-measure.
    ///
    /// The measurement compares **this prompt with symbols against the same
    /// prompt written out in full** — not against the raw request.
    ///
    /// Comparing against the request was wrong, and wrong in a way that made the
    /// feature look broken: a compiled prompt is *supposed* to be longer than
    /// what was dictated, because it adds the scope boundary, the acceptance
    /// criterion and the structure that the spoken sentence left implicit. On a
    /// realistic request that comparison read `−95%`, which is not a compression
    /// failure but a category error — unstructured input against a structured
    /// specification is not a before/after of the same thing.
    ///
    /// Symbols against their own expansion is the like-for-like measurement, and
    /// it is also the one Compact Constraint Encoding (arXiv 2604.07192) reports
    /// — a ~71% cut to the constraint portion with no measurable loss of
    /// compliance. `baseline` is accepted and ignored, for callers that pass the
    /// raw request.
    func render(baseline: String? = nil) {
        guard let current = ir else {
            artifact = nil
            comparison = nil
            return
        }
        func options(
            symbolMode: PromptSymbolMode,
            expandsRecognisedConstraints: Bool = false
        ) -> PromptRenderOptions {
            PromptRenderOptions(
                kind: .prompt,
                language: settings.promptOutputLanguage,
                symbolMode: symbolMode,
                rulebook: activeRulebook,
                syncedSymbols: syncedSymbols,
                layout: settings.promptLayout,
                detail: settings.promptDetailLevel,
                expandsRecognisedConstraints: expandsRecognisedConstraints
            )
        }
        let rendered = PromptRenderer.render(current, options: options(symbolMode: settings.promptSymbolMode))
        artifact = rendered

        // No symbols in play means nothing was compressed, and showing a 0%
        // saving next to an unchanged prompt just adds noise.
        guard !rendered.usedSymbols.isEmpty else {
            comparison = nil
            return
        }
        // The baseline is the same prompt with every constraint written out in
        // full — what the reader would have had to read without the symbols.
        let expanded = PromptRenderer.render(
            current, options: options(symbolMode: .off, expandsRecognisedConstraints: true)
        )
        comparison = meter.compare(before: expanded.content, after: rendered.content)
        refineCounts(before: expanded.content, after: rendered.content)
    }

    /// Ask the real tokenizer for both numbers, then re-measure.
    ///
    /// Off the render path because tokenizing needs the model actor, and the
    /// preview must not wait on it. When the model is not loaded this does
    /// nothing at all — counting text in a field must never pull 2.3 GB into
    /// memory — and the heuristic reading stands, labelled as an estimate.
    private func refineCounts(before: String, after: String) {
        // Tracked, because it reaches into the shared model container. An
        // untracked task could still be inside `container.perform` when a
        // meeting start or `releaseQwen()` calls `unload()` — the same
        // mid-flight teardown every other generation path is drained for.
        countRefinement?.cancel()
        countRefinement = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard let exactBefore = await self.qwenHost.countTokens(before),
                  let exactAfter = await self.qwenHost.countTokens(after)
            else { return }
            // Cancellation does not interrupt an in-flight `container.perform`,
            // so a superseded task resumes and would publish the *previous*
            // render's counts — labelled exact, with nothing to signal they are
            // stale. Cache them (they stay true for that text) but do not
            // display them.
            guard !Task.isCancelled else { return }
            self.tokenCounter.store(exactBefore, for: before)
            self.tokenCounter.store(exactAfter, for: after)
            self.comparison = TokenComparison(
                before: exactBefore, after: exactAfter, source: .modelTokenizer
            )
        }
    }

    /// Symbols already present in the target project, so the renderer knows
    /// whether bare symbols are safe.
    ///
    /// Cached, because this walks `.claude/rules/`, reads every file in it and
    /// reads `AGENTS.md`, and `render()` runs on every keystroke in the rulebook
    /// editor — which made typing a rule description do a directory enumeration
    /// and a handful of file reads per character, on the main thread.
    ///
    /// Invalidated whenever the project path changes or a sync writes new files,
    /// which are the only two ways the answer can change from inside the app. A
    /// teammate committing a rules file is picked up on the next launch or path
    /// change; that staleness is the same one the previous code had between two
    /// renders, and the renderer already degrades safely when a symbol turns out
    /// to be undefined.
    private var syncedSymbolsCache: Set<String>?
    private var syncedSymbolsCachedFor: String?

    private var syncedSymbols: Set<String> {
        guard let root = settings.promptTargetProjectPath, !root.isEmpty else { return [] }
        if syncedSymbolsCachedFor == root, let cached = syncedSymbolsCache { return cached }
        let symbols = PromptArtifactWriter.allSyncedSymbols(inProjectAt: root)
        syncedSymbolsCache = symbols
        syncedSymbolsCachedFor = root
        return symbols
    }

    /// The current IR rendered for a different surface — a skill or a slash
    /// command — without disturbing the prompt on screen.
    func artifact(as kind: PromptArtifactKind) -> PromptArtifact? {
        guard let current = ir else { return nil }
        return PromptRenderer.render(
            current,
            options: PromptRenderOptions(
                kind: kind,
                language: settings.promptOutputLanguage,
                symbolMode: settings.promptSymbolMode,
                rulebook: activeRulebook,
                syncedSymbols: syncedSymbols,
                layout: settings.promptLayout,
                detail: settings.promptDetailLevel
            )
        )
    }

    /// The rulebook as this project actually uses it: only the enabled
    /// categories.
    ///
    /// Filtered here rather than only at sync time: otherwise the compressor can
    /// emit a symbol from a switched-off category, that symbol fails to resolve,
    /// and `effectiveMode` downgrades on *any* unresolved symbol — so turning off
    /// one category silently disables symbols for the whole prompt. One toggle,
    /// one meaning: a category that is off does not exist for this project.
    var activeRulebook: PromptRulebook {
        rulebook.filtered(to: settings.promptRuleCategories)
    }

    /// Drop the cached symbol set. Call after writing artifacts into the project.
    func invalidateSyncedSymbols() {
        syncedSymbolsCache = nil
        syncedSymbolsCachedFor = nil
    }

    /// Coalesce a burst of rulebook edits into one save and one re-render.
    ///
    /// Short enough that the preview still feels live, long enough that holding
    /// a key down costs one commit rather than one per repeat.
    private func scheduleRulebookCommit() {
        rulebookCommit?.cancel()
        rulebookCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            RulebookStore.save(self.rulebook)
            self.render()
        }
    }

    /// Estimated one-off cost of the rulebook, and how many uses it takes to pay
    /// for itself. Shown next to the per-prompt saving so the number is honest.
    var rulebookTokenCost: Int {
        TokenEstimator.estimate(rulebookFile)
    }

    /// Lines in the generated `.claude/rules/` file.
    ///
    /// Surfaced because this file loads at **every** session start, so its size
    /// is a standing tax on every conversation in the project rather than a
    /// per-prompt cost. Anthropic's own guidance caps session-loaded instruction
    /// files at a couple of hundred lines, and their engineering write-ups
    /// report cutting most of Claude Code's own system prompt with no measurable
    /// loss — a long rulebook is not free, and a rule the project never uses is
    /// pure overhead.
    var rulebookLineCount: Int {
        rulebookFile.components(separatedBy: "\n").count
    }

    /// Whether the rulebook has grown past the point where it is worth pruning.
    var rulebookIsOversized: Bool { rulebookLineCount > 200 }

    /// Cached: three view-body properties read this, and SwiftUI re-evaluates
    /// the body on every published phase tick during a compile — so one compile
    /// re-rendered the whole 52-rule file dozens of times on the MainActor.
    private var rulebookFileCache: (key: String, content: String)?

    private var rulebookFile: String {
        // Measured on the book that actually gets installed. Reporting the full
        // 52 rules while only some are written meant the per-session cost was
        // wrong for anyone who narrowed the categories — and being wrong in the
        // expensive direction is what makes people stop reading the number.
        let active = activeRulebook
        // `rulebookRevision`, not a structural fingerprint. Rule count, language
        // and symbol names all stay the same when you rewrite a rule's text, so a
        // key built from those never invalidated and the token cost, the line
        // count and the oversize warning stayed frozen at their pre-edit values
        // for the rest of the session.
        let key = "\(rulebookRevision)|\(settings.promptOutputLanguage.rawValue)|"
            + active.symbols.sorted().joined(separator: ",")
        if let cached = rulebookFileCache, cached.key == key { return cached.content }
        let content = PromptRenderer.renderRulebook(
            active, language: settings.promptOutputLanguage
        ).content
        rulebookFileCache = (key, content)
        return content
    }

    // MARK: - Reset

    func clear() {
        // Cancel first. A compile or tidy in flight captured the request before
        // the clear and would finish afterwards, restoring the IR, the artifact
        // and — during a tidy — the exact text that was just deleted.
        let wasWorking = phase.isBusy
        work?.cancel()
        countRefinement?.cancel()
        phase = .idle
        // Arm the release. Cancelling a generation does not un-load the model,
        // and the cancelled task returns early past its own `didFinishWork()`, so
        // nothing else was going to schedule it — Clear during a compile left the
        // container resident for the rest of the session.
        if wasWorking { didFinishWork() }
        inputText = ""
        interimText = ""
        origin = .typed
        ir = nil
        findings = []
        artifact = nil
        comparison = nil
        statusMessage = ""
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
