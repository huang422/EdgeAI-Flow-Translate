import AppKit
import SwiftUI
import FlowTranslateCore

/// Caption / language settings (US3) + overlay presentation (redesign §4). Bound to
/// the live `CaptionSettings`, applied immediately and persisted.
struct SettingsView: View {
    /// Which half of the app the settings are about.
    enum Pane: Hashable { case captions, prompt }

    @Binding var settings: CaptionSettings
    @ObservedObject var vm: CaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false
    /// Result of the last dictation-permissions reset, or nil if not run yet.
    /// `tccutil` reports success or failure per service and the user cannot see
    /// either otherwise — the entries it removes are invisible until the next
    /// launch.
    @State private var promptPermissionsReset: Permissions.ResetReport?
    /// The same, for the captions page's own reset.
    @State private var captionPermissionsReset: Permissions.ResetReport?
    /// "Loads N rules · N lines · ≈N tokens per session", recomputed only when
    /// the inputs to it change.
    @State private var rulebookCost = ""
    /// Whether the built-in recognizer is usable, held in state so the row
    /// updates when the probe finishes.
    ///
    /// `DictationEngineFactory.builtInAvailable` is a plain static — reading it
    /// from a view body creates no dependency, so a sheet opened before the probe
    /// completed showed "unavailable" forever.
    @State private var builtInEngineAvailable = DictationEngineFactory.builtInAvailable
    /// Opens on the pane matching the tab the user came from. Landing on
    /// caption settings after pressing ⌘, from the Prompt tab means finding the
    /// right pane before reading anything, every time.
    @State private var pane: Pane

    init(settings: Binding<CaptionSettings>, vm: CaptureViewModel, initialPane: Pane = .captions) {
        self._settings = settings
        self.vm = vm
        self._pane = State(initialValue: initialPane)
    }

    /// Latency tiers whose model is already on disk for the selected language.
    /// `nil` until the first check, so the row never flashes "needs download"
    /// before it knows. Recomputed only when the language changes: the check
    /// hits the filesystem and a Form body re-renders on every slider tick.
    @State private var cachedTiers: Set<String>?

    private static let tiers = ["560ms", "1120ms", "2240ms"]

    /// Which tiers are ready and which would cost a download, for the CURRENT
    /// language. Every latency tier is a separate ~600 MB model, and Latin and
    /// multilingual are separate sets again — so switching language changes
    /// every answer here. Without this the first hint you get is a surprise
    /// download prompt AFTER you've already switched.
    private var tierStatus: (text: String, complete: Bool)? {
        guard let cachedTiers else { return nil }
        let ready = Self.tiers.filter(cachedTiers.contains)
        let missing = Self.tiers.filter { !cachedTiers.contains($0) }
        guard !missing.isEmpty else {
            return ("Models: all three tiers are downloaded for this language.", true)
        }
        var s = "Models: "
        if !ready.isEmpty { s += ready.joined(separator: ", ") + " ready · " }
        s += missing.joined(separator: ", ")
            + (missing.count == 1 ? " needs" : " each need")
            + " a ~600 MB download, fetched on the next Start."
        return (s, false)
    }

    /// Segmented "visible lines" (1/2/3) maps to `historyLineCount` (0/1/2 = now + N).
    private var visibleLines: Binding<Int> {
        Binding(get: { settings.historyLineCount + 1 },
                set: { settings.historyLineCount = max(0, min(2, $0 - 1)) })
    }

    /// Explains the active translation-engine behavior for the current settings.
    private var engineHint: String {
        if settings.firstLanguage == "auto" {
            return "Auto-detect always uses the on-device Qwen model "
                + "(Apple Translation can't auto-detect the source language)."
        }
        switch settings.translationEngine {
        case .system:
            return "Prefers Apple's on-device translation (fastest); unsupported "
                + "language pairs automatically fall back to the Qwen model."
        case .qwen:
            return "Always uses the on-device Qwen model (context-aware quality; "
                + "loads into memory on the first translation)."
        }
    }

    /// Chooses which rule categories get installed into the project.
    ///
    /// `.claude/rules/` loads at **every** session start, so an unused category
    /// is not a one-off cost — it is a tax on every conversation in that
    /// project. Narrowing the set is safe: the renderer detects any symbol the
    /// project cannot resolve and writes that constraint out in full instead, so
    /// deselecting a category can make a prompt longer but never leaves it with
    /// an identifier nothing defines.
    /// Rules per category, for the book that will actually be installed.
    ///
    /// Measured on `vm.activePromptRulebook`, not on `PromptStdlib.all`. Anyone
    /// who added or rewrote a rule in the editor was reading a cost for a file
    /// they do not have — Settings said "52 rules", the Prompt page's own readout
    /// said something else, and `syncRules` wrote a third thing. Recomputed with
    /// the cost rather than cached for the process, because the answer is now
    /// per-user and can change while the app is running.
    @State private var ruleCounts: [RuleCategory: Int] = [:]

    private func refreshRulebookCost() {
        // Read the book ONCE. `activePromptRulebook` and
        // `activePromptRulebookIgnoringCategories` each decode the whole 52-rule
        // book out of `UserDefaults` when the Prompt tab has never been opened,
        // so calling both meant two full `JSONDecoder` passes per refresh — and
        // this runs on appear and on three separate `onChange` handlers.
        let book = vm.activePromptRulebookIgnoringCategories
        let selected = book.filtered(to: settings.promptRuleCategories)
        // Rendered for the selected agent too: Claude's fuller phrasing and
        // Codex's short declaratives are different files with different costs,
        // and this is the number that says how much every session pays.
        let file = PromptRenderer.renderRulebook(
            selected, language: settings.promptOutputLanguage,
            backend: settings.promptLayout.backend
        ).content
        rulebookCost = "Loads \(selected.rules.count) rules · "
            + "\(file.components(separatedBy: "\n").count) lines · "
            + "≈\(TokenEstimator.estimate(file)) tokens per session"
        // The unfiltered book, so each row shows how many rules that category
        // would add rather than how many are switched on right now.
        ruleCounts = Dictionary(
            uniqueKeysWithValues: RuleCategory.allCases.map { ($0, book.rules(in: $0).count) }
        )
    }

    @ViewBuilder private var ruleCategoryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(RuleCategory.allCases) { category in
                let count = ruleCounts[category] ?? 0
                Toggle(isOn: Binding(
                    get: { settings.promptRuleCategories.contains(category) },
                    set: { on in
                        if on { settings.promptRuleCategories.insert(category) }
                        else { settings.promptRuleCategories.remove(category) }
                    }
                )) {
                    HStack {
                        Text(category.displayName).font(.caption)
                        Spacer()
                        Text("\(count) rules").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            // Computed on change, not on every body pass.
            //
            // This renders the whole 52-rule markdown file, splits it and
            // estimates its tokens — about 1 ms — and it sat directly in the
            // body. The Settings window observes the view model, so while a
            // meeting ran it was rebuilt at the caption and level-meter rate and
            // paid that millisecond every time. That is most of why opening
            // Settings felt heavy.
            Text(rulebookCost)
                .font(.caption2).foregroundStyle(.secondary)
            Text("This file loads at the start of every Claude Code session, so a category "
                + "the project never uses is a standing cost on every conversation in it. "
                + "Unticking one only means those constraints are written out in full "
                + "instead of as symbols — nothing stops working.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Grades the whole prompt pipeline against the real model.
    ///
    /// Lives in Settings rather than the Prompt tab because it is a diagnostic,
    /// not a feature: it spends minutes of GPU time and blocks every other model
    /// path while it runs. The scorecard is selectable so it can be pasted into
    /// an issue — a claim that the feature got better or worse is worth little
    /// without one.
    @ViewBuilder private var evalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("品質評量 Quality eval").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let progress = vm.promptEval.progress {
                    Text("\(progress.done)/\(progress.total) · \(progress.currentCase)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("停止 Stop") { vm.promptEval.cancel() }.font(.caption)
                } else {
                    Button("執行 Run") { vm.promptEval.run() }
                        .font(.caption)
                }
            }
            Text("Runs \(PromptEvalCases.all.count) English, Chinese and code-switched "
                + "requests through the real model and scores identifier survival, whether "
                + "any prohibition was inverted, and whether the intent was captured. "
                + "Occupies the model for several minutes; meetings and summaries are "
                + "blocked while it runs.")
                .font(.caption2).foregroundStyle(.secondary)

            if !vm.promptEval.tokenAccuracy.isEmpty {
                Text(vm.promptEval.tokenAccuracy)
                    .font(.caption2).textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            if !vm.promptEval.statusMessage.isEmpty {
                Text(vm.promptEval.statusMessage).font(.caption2).foregroundStyle(.orange)
            }
            if let scorecard = vm.promptEval.pasteableReport {
                ScrollView {
                    Text(scorecard)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                HStack {
                    Spacer()
                    Button("複製 Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(scorecard, forType: .string)
                    }
                    .font(.caption)
                }
            }
        }
    }

    /// Says what compression does, now that it does one thing.
    private var compressionHint: String {
        "Fixed at Balanced. Removes courtesy, filler, articles and auxiliaries, and contracts "
            + "what it can — measured at −21% on English, still readable. Constraints and file "
            + "paths are never touched. Chinese sits at about −5%: Apple's NaturalLanguage gives "
            + "no part of speech or lemma for it, so only the courtesy layer applies. Speaking "
            + "Chinese costs nothing — with English output the pruning runs on the prompt."
    }

    /// Says which recognizer dictation will actually use, and what that costs.
    ///
    /// The resolved engine, not the setting: `automatic` means two different
    /// things on two different systems, and the one thing a user needs from this
    /// row is which one they are getting.
    private var engineHintForDictation: String {
        guard builtInEngineAvailable else {
            // Two different reasons, two different fixes. Saying "needs macOS 26"
            // on a macOS 26 machine — which happens whenever no dictation
            // language is set up, because `supportedLocales` is then empty —
            // sent the user looking for an OS upgrade they already have.
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            guard major >= 26 else {
                return "The built-in recognizer needs macOS 26; this Mac is on "
                    + "macOS \(major), so dictation uses Nemotron."
            }
            return "The built-in recognizer reports no available languages on this Mac. "
                + "Add a dictation language in System Settings → Keyboard → Dictation, "
                + "then reopen this window. Dictation uses Nemotron until then."
        }
        let resolved = DictationEngineFactory.resolved(settings)
        let base = resolved == .appleSpeech
            ? "Using the built-in macOS recognizer: punctuation arrives already applied, "
                + "and its language assets are managed by the system rather than downloaded here."
            : "Using the bundled Nemotron model (~600 MB per language and latency tier)."
        // The one thing that is genuinely lost, said plainly. Captions keep
        // Nemotron either way, so this is about dictation only.
        return base + " Captions always use Nemotron — speaker diarization runs "
            + "inside that pipeline and the built-in recognizer has no equivalent. "
            + "Either way the transcript goes through the same Qwen tidy pass."
    }

    /// Explains what the chosen dictation language actually costs.
    ///
    /// Engine-aware, because the two answers have nothing in common: on a macOS
    /// 26 Mac dictation runs on the built-in recognizer and not one byte of
    /// Nemotron is fetched for it.
    ///
    /// For Nemotron: variants are keyed by language, and `auto` selects the
    /// multilingual ship, so the cost depends on whether dictation and captions
    /// land in the same ship rather than on which one you picked.
    private var dictationLanguageHint: String {
        guard DictationEngineFactory.resolved(settings) == .nemotron else {
            return "The built-in recognizer ships with macOS — nothing is downloaded here. Its "
                + "per-language assets are the system's, fetched once on first use and shared "
                + "with system dictation; a language already set up in System Settings → "
                + "Keyboard → Dictation costs nothing. The Prompt page marks the ones still "
                + "missing with ⬇. It recognizes one language per session and has no mixed "
                + "mode, so the Prompt page does not offer 混說 for it — pick Nemotron if you "
                + "code-switch."
        }
        let dictation = PromptDictation.language(for: settings)
        if dictation == "auto" {
            return "Mixed speech uses the multilingual weights. Free if the captions language is "
                + "already non-Latin; if it is English, this is a second ~600 MB variant plus a "
                + "model reload every time you switch between a meeting and dictation."
        }
        let captionShip = NemotronStreamingService.shipDirectory(for: settings.firstLanguage)
        let dictationShip = NemotronStreamingService.shipDirectory(for: dictation)
        if captionShip == dictationShip {
            return "Shares the captions language's weights. No extra download."
        }
        return "A different variant from the captions language: an extra ~600 MB download, and a "
            + "model reload (2–4 s) every time you switch between a meeting and dictation."
    }

    /// Explains the segmentation trade-off of the selected scenario. The mic is
    /// always live speech, so it always uses the meeting timing.
    private var scenarioHint: String {
        switch settings.scenario {
        case .video:
            return "Edited content (videos, courses): sentences split after a 0.3 s pause "
                + "for snappier captions. Applies on the next Start; the mic always uses meeting timing."
        case .meeting:
            return "Live speakers: tolerates 0.8 s thinking pauses so sentences aren't cut in half. "
                + "Applies on the next Start; the mic always uses meeting timing."
        }
    }

    /// A sheet has no title bar, so it has nowhere to put a `.toolbar`. Asking
    /// for one anyway laid the Done button over the `TabView`'s tab strip and
    /// pushed both past the top edge. The standard macOS sheet shape is used
    /// instead: content, a divider, and the dismissing button on its own row.
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $pane) {
                captionsPane
                    .tabItem { Label("即時字幕 Live captions", systemImage: "captions.bubble") }
                    .tag(Pane.captions)
                promptPane
                    .tabItem { Label("提示詞編譯 Prompt composer", systemImage: "wand.and.stars") }
                    .tag(Pane.prompt)
            }
            // The tab strip is drawn inside the TabView's own bounds and sits
            // flush against the sheet's rounded top corners without this.
            .padding(.top, 10)
            .padding(.horizontal, 10)

            Divider()

            HStack {
                Spacer()
                Button("完成 Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 660)
        .onAppear {
            refreshRulebookCost()
        }
        .task {
            // Re-probed rather than trusted: the first probe runs at launch, and
            // a language added in System Settings since then changes the answer.
            await DictationEngineFactory.refreshAvailability()
            builtInEngineAvailable = DictationEngineFactory.builtInAvailable
        }
        .onChange(of: settings.promptRuleCategories) { _, _ in refreshRulebookCost() }
        .onChange(of: settings.promptOutputLanguage) { _, _ in refreshRulebookCost() }
        // The agent decides which phrasing of each rule is written, so it decides
        // the file's size too.
        .onChange(of: settings.promptLayout) { _, _ in refreshRulebookCost() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in refreshRulebookCost() }
        .confirmationDialog("解除安裝 FlowTranslate？", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("移到垃圾桶並刪除模型 Uninstall") { vm.uninstall() }
            Button("取消 Cancel", role: .cancel) {}
        } message: {
            Text("Removes downloaded models, transcripts, settings and this app's privacy-permission entries, then moves the app to the Trash.")
        }
    }

    /// Everything about capturing and translating speech.
    ///
    /// Split from the prompt settings because the two features share nothing but
    /// the models underneath: someone tuning caption latency is never also
    /// choosing a target coding agent, and one scrolling column of nine sections
    /// made both harder to find.
    private var captionsPane: some View {
        Form {
            Section("使用情境 Scenario") {
                Picker(selection: $settings.scenario) {
                    Text("🎬 Video").tag(CaptureScenario.video)
                    Text("👥 Meeting").tag(CaptureScenario.meeting)
                } label: { Text("系統聲的內容 System audio is") }
                .pickerStyle(.segmented)
                Text(scenarioHint)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("辨識 Recognition") {
                Picker("第一字幕（Original）", selection: $settings.firstLanguage) {
                    Text("自動 Auto").tag("auto")
                    ForEach(SupportedASRLanguages.all) { locale in
                        Text("\(locale.displayName) (\(locale.code))").tag(locale.code)
                    }
                }
                if settings.firstLanguage == "auto" {
                    // Auto isn't just "no language lock" — it loads a different,
                    // larger build. Worth saying plainly, because picking the
                    // language is the cheapest accuracy win available.
                    Text("Auto-detect loads the full 13,087-token multilingual model. "
                        + "Naming the language instead loads a vocabulary-pruned build "
                        + "(2,828 tokens for English and other Latin-script languages) and "
                        + "locks the decoder to it — far fewer confusable words. Use Auto "
                        + "only when the audio really does switch languages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Labelled by what actually differs between them.
                //
                // Not Lowest / Balanced / **Accurate**, which is not what the
                // tiers are: FluidAudio measures 2.28% WER at
                // 560 ms, 2.28% at 1120 ms and 2.46% at 2240 ms, and says
                // outright that "WER is neutral across tiers (within n=100
                // noise)". What changes is chunk latency and throughput
                // (42.1× → 65.0× → 93.6× RTFx). Calling one of them "accurate"
                // sold a caption-latency cost as a quality gain.
                Picker("延遲層級 Latency", selection: $settings.asrTier) {
                    Text("Fastest 560ms").tag("560ms")
                    Text("Balanced 1120ms").tag("1120ms")
                    Text("Smoothest 2240ms").tag("2240ms")
                }
                .pickerStyle(.segmented)
                // Re-checked whenever the language changes — Latin and
                // multilingual ships have independent per-tier caches.
                .task(id: settings.firstLanguage) {
                    cachedTiers = Set(Self.tiers.filter {
                        NemotronStreamingService.variantPresent(
                            language: settings.firstLanguage, tier: $0)
                    })
                }
                Text("How much audio the recognizer takes per step. FluidAudio measures "
                    + "accuracy as neutral across all three (2.28% / 2.28% / 2.46% WER, "
                    + "within benchmark noise) — what changes is how often the caption "
                    + "updates and how much CPU it costs. 560ms updates while the speaker "
                    + "is still talking; 2240ms is FluidAudio's default and is 2.2× the "
                    + "throughput. Each tier is a separate ~600 MB model. "
                    + "Applies on the next Start.")
                    .font(.caption).foregroundStyle(.secondary)
                if let tierStatus {
                    Text(tierStatus.text)
                        .font(.caption)
                        .foregroundStyle(tierStatus.complete ? .secondary : Color.orange)
                }
                Toggle(isOn: $settings.diarizationEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("講者辨識 Speaker diarization")
                        Text("pyannote 3.1 + WeSpeaker label speakers per source (~60 MB download). "
                            + "Runs an inference per finalized sentence, so it costs CPU throughout "
                            + "a meeting. Speakers are named 「Claude Mango」 rather than 「Speaker 1」. "
                            + "Applies on the next Start.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if settings.diarizationEnabled {
                    // Exposed rather than fixed: the two ways diarization goes
                    // wrong need opposite corrections, and which one a user hits
                    // depends on their room. Two people on one microphone
                    // over-segment; five on a conference call under-segment.
                    Picker(selection: $settings.diarizationSensitivity) {
                        ForEach(DiarizationSensitivity.allCases) { Text($0.displayName).tag($0) }
                    } label: {
                        Text("分辨靈敏度 Sensitivity")
                    }
                    .pickerStyle(.segmented)
                    Text(settings.diarizationSensitivity.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $settings.keepAcousticContext) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("跨句聲學上下文 Carry acoustic context (experimental)")
                        Text("The encoder holds 3.36 s of audio history, which is normally cleared "
                            + "at every sentence end — so each sentence starts cold. Keeping it may "
                            + "sharpen the opening words, but it also skips the language-lock re-seed "
                            + "and can make one sentence run on into the next. Compare both on your "
                            + "own speech. Applies on the next Start.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("翻譯 Translation") {
                Toggle("第二字幕（Translation）", isOn: $settings.secondCaptionEnabled)
                Picker("翻譯目標 Target", selection: $settings.secondLanguage) {
                    ForEach(SecondCaptionLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .disabled(!settings.secondCaptionEnabled)
                Picker("翻譯引擎 Engine", selection: $settings.translationEngine) {
                    ForEach(TranslationEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .disabled(!settings.secondCaptionEnabled || settings.firstLanguage == "auto")
                Text(engineHint)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("逐字稿 Transcript") {
                Toggle(isOn: $settings.transcriptCorrectionEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI 校正逐字稿 AI transcript correction")
                        Text("Qwen fixes homophones, names and punctuation in the recorded "
                            + "transcript. Live captions are never delayed or rewritten. "
                            + "Keeps the model resident (~2.3 GB) for the whole meeting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }


            Section("懸浮字幕 Overlay") {
                Picker(selection: $settings.primaryLineOnTop) {
                    Text("Original").tag(PrimaryLine.original)
                    Text("Translation").tag(PrimaryLine.translation)
                } label: { Text("哪個語言在上面 Primary line") }
                .pickerStyle(.segmented)

                Picker(selection: visibleLines) {
                    Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                } label: { Text("同時顯示句數 Visible lines") }
                .pickerStyle(.segmented)

                Text("How many caption units the band keeps. Its height follows the text "
                    + "automatically — the box is as tall as what it is showing, pinned by "
                    + "its bottom edge, so the newest line never moves.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker(selection: $settings.interimStyle) {
                    Text("Caret + underline").tag(InterimStyle.markedWithCaret)
                    Text("Hidden").tag(InterimStyle.hidden)
                } label: { Text("辨識中的文字 Interim text") }
                .pickerStyle(.segmented)

                HStack {
                    Text("字級 Font size")
                    Slider(value: $settings.overlayFontSize,
                           in: CaptionTheme.Metric.fontMin...CaptionTheme.Metric.fontMax, step: 1)
                    Text("\(Int(settings.overlayFontSize))pt").monospacedDigit().foregroundStyle(.secondary)
                }

                HStack {
                    Text("背景透明度 Opacity")
                    Slider(value: $settings.overlayOpacity,
                           in: CaptionTheme.Metric.opacityMin...CaptionTheme.Metric.opacityMax)
                    Text("\(Int(settings.overlayOpacity * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.clickThrough) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("點擊穿透 Click-through")
                        Text("Captions don't block clicks to other apps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $settings.autoCloseOverlayOnStop) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("停止後自動關閉 Auto-close on stop")
                        Text("Hides the floating captions when you stop a meeting")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("音訊輸入 Audio input") {
                Toggle(isOn: $settings.autoGainEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("自動增益 Auto-gain")
                        Text("Automatically boosts quiet speakers toward a target level")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("系統聲增益 System gain")
                    Slider(value: $settings.systemInputGainDb, in: 0...CaptionSettings.maxInputGainDb, step: 1)
                    Text("+\(Int(settings.systemInputGainDb)) dB").monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Text("麥克風增益 Mic gain")
                    Slider(value: $settings.micInputGainDb, in: 0...CaptionSettings.maxInputGainDb, step: 1)
                    Text("+\(Int(settings.micInputGainDb)) dB").monospacedDigit().foregroundStyle(.secondary)
                }
                Text("Raise a quiet meeting participant so they clear the voice-detection "
                    + "threshold. A soft limiter prevents clipping/distortion.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Label {
                    Text("Runs entirely on-device. Audio and text never leave your Mac — only the first-time model download needs the internet.")
                        .font(.caption).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(CaptionTheme.Palette.privacy)
                }
            }
            // Same title and the same order as the Prompt pane's: settings
            // resets first, then the app-level action, then the privacy reset
            // last. See that section for why.
            Section("維護 Maintenance") {
                VStack(alignment: .leading, spacing: 3) {
                    Button("重設 Reset caption settings") {
                        settings.resetCaptionSettings()
                    }
                    Text("Restores the caption, translation, overlay and audio settings to their "
                        + "defaults. Prompt Composer settings are untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Button("解除安裝 Uninstall") { confirmUninstall = true }
                    Text("Removes downloaded models, transcripts and settings, and moves the app "
                        + "to the Trash.")
                        .font(.caption).foregroundStyle(.secondary)
                }


                VStack(alignment: .leading, spacing: 3) {
                    // No `dismiss()`. Closing the window was hiding the only
                    // report the reset produces — `tccutil` names which services
                    // it cleared and why any of them failed, and that landed in a
                    // status line behind a sheet that had just shut.
                    Button("重設權限 Reset permissions") {
                        Task { captionPermissionsReset = await vm.resetPrivacyPermissions() }
                    }
                    Text("Clears this app's Microphone, Screen Recording and Accessibility "
                        + "privacy entries. Relaunch and grant them again. Use after replacing "
                        + "the app when the toggles look ON but capture fails.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let report = captionPermissionsReset {
                        Text(report.summary)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(report.isCompleteSuccess
                                             ? CaptionTheme.Palette.mic : .orange)
                    }
                }
            }

            PermissionsIndicator()
        }
        .formStyle(.grouped)
    }

    /// Everything about turning speech or typing into a prompt.
    private var promptPane: some View {
        Form {
            Section("關於 About") {
                Text("Compiles a spoken or typed request into a prompt for Claude Code or "
                    + "Codex. Shares the ASR and Qwen models with captions and never runs "
                    + "alongside a meeting, so it adds no resident memory.")
                    .font(.caption).foregroundStyle(.secondary)
                // Target agent, output language, dictation language, symbol mode
                // and the hotkey toggle all live on the Prompt page: each is a
                // per-request decision made while looking at the result. Only the
                // explanation stays here.
                Text(dictationLanguageHint)
                    .font(.caption).foregroundStyle(.secondary)

            }

            Section("辨識引擎 Recognizer") {
                // The built-in recognizer is macOS 26+, and only once the system
                // has a dictation language set up. When it is not there, the
                // *row* says so and the picker stays usable — disabling the whole
                // control also took away the choice between Automatic and
                // Nemotron, and left a stored "Built-in" selected and unchangeable
                // while Nemotron was quietly doing the work. `resolved` already
                // falls back for every choice, so the only thing missing was
                // saying which row is inert.
                Picker("口述引擎 Dictation engine", selection: $settings.promptDictationEngine) {
                    ForEach(DictationEngineChoice.allCases) { choice in
                        Text(choice == .appleSpeech && !builtInEngineAvailable
                             ? "\(choice.displayName)（此 Mac 不可用）"
                             : choice.displayName)
                            .tag(choice)
                    }
                }
                Text(engineHintForDictation)
                    .font(.caption).foregroundStyle(.secondary)
            }

            // The agent and language pickers live on the Prompt page itself:
            // both are per-request choices made while looking at the result, not
            // preferences set once and forgotten. Duplicating them here meant two
            // controls for one value, and a trip to Settings to change something
            // the page could show.
            Section("輸出格式 Output format") {
                // The sync destination follows the target agent chosen on the
                // Prompt page: Claude Code reads `.claude/rules/`, Codex and
                // friends read AGENTS.md, and neither reads the other's. A
                // separate switch here meant one question with two answers.
                // Compression is no longer a setting. It was a three-way picker —
                // 保守 / 平衡 / 激進 — whose outer two options nobody could choose
                // between on any stated grounds: 保守 measured −4% against 平衡's
                // −21% and bought nothing, and 激進 reached −23% by adding
                // lemmatization, two points for prose a human can no longer
                // comfortably review. See `CompressionProfile.balanced`.
                Text(compressionHint)
                    .font(.caption).foregroundStyle(.secondary)

                // The target agent lives on the Prompt page. Two controls bound
                // to one value is one control too many, and this is the one you
                // change while looking at the output.
                Picker(selection: $settings.promptQuickInsertMode) {
                    ForEach(PromptQuickInsertMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: { Text("⌃⌥Space 插入內容 Hotkey inserts") }
                Text(settings.promptQuickInsertMode.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Also switchable from the dictation panel itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // The project folder and "sync rules" both live on the Prompt page:
            // each changes what a compile produces, so they belong beside the
            // button rather than behind ⌘,.
            Section("規則本 Rulebook") {
                ruleCategoryPicker
            }

            Section("診斷 Diagnostics") {
                evalRow
            }

            // **Titled and ordered like the captions page's own.** The two panes
            // ended up with one "維護 Maintenance" and one "重設 Reset" holding
            // the same kinds of control in a different order, so a user crossing
            // between them had to re-find every button. Both are now 維護, both
            // run settings-resets first and the privacy reset last, and the
            // permission reset is the last thing on both pages — it is the one
            // that needs a relaunch, and the furthest from anything routine.
            Section("維護 Maintenance") {
                VStack(alignment: .leading, spacing: 3) {
                    Button("重設 Reset prompt settings") {
                        settings.resetPromptSettings()
                    }
                    Text("Restores the target agent, languages, symbol mode, project folder and "
                        + "rule categories to their defaults. Caption settings and your edited "
                        + "rulebook are untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("重設規則本 Reset rulebook") { RulebookStore.reset() }
                    Text("Discards your edits and restores the 52 bundled rules. Takes effect the "
                        + "next time the Prompt tab is opened.")
                        .font(.caption).foregroundStyle(.secondary)

                    // Last on the page, matching the captions pane. It is a
                    // repair tool, not part of setting the feature up, and a
                    // destructive-sounding button in the middle of the controls
                    // you use every day invites a press nobody wanted.
                    //
                    // Dictation depends on two grants — Microphone to hear,
                    // Accessibility to type at the cursor — and both are keyed to
                    // the app's code signature, so after a rebuild or a reinstall
                    // the toggle reads ON while the permission silently fails.
                    // Screen Recording is deliberately left alone: dictation does
                    // not use it, and taking it away from this page would revoke
                    // something this page never asked for.
                    Button("重設口述權限 Reset dictation permissions") {
                        promptPermissionsReset = Permissions.resetPrivacyPermissions(
                            services: Permissions.dictationServices
                        )
                    }
                    Text("Clears this app's Microphone and Accessibility entries. Relaunch "
                        + "and grant them again. Screen Recording is left alone — dictation "
                        + "does not use it.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let report = promptPermissionsReset {
                        // The report's own words, including `tccutil`'s reason for
                        // any service that failed. "重設失敗" alone named neither
                        // which service nor why, and its advice — run the same
                        // command by hand — fails identically when the cause is
                        // that LaunchServices cannot resolve this bundle ID.
                        Text(report.summary)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(report.isCompleteSuccess
                                             ? CaptionTheme.Palette.mic : .orange)
                    }
                }
            }

            PermissionsIndicator()
        }
        .formStyle(.grouped)
    }
}
