import SwiftUI
import FlowTranslateCore

/// Main control panel (redesign §3): a title bar with a live status pill, two
/// source toggle cards with volume meters, a single Start/Stop action, a language
/// chip, and a transcript that shares the overlay's visual language.
struct ContentView: View {
    /// Injected app-level view model (a single instance for the whole app), so
    /// closing and reopening the window never spawns a second overlay / hotkey set.
    @ObservedObject var vm: CaptureViewModel
    @State private var showSettings = false
    @State private var tab: MainTab = .captions

    private static let bottomAnchor = "TRANSCRIPT_BOTTOM"

    /// The two panes of the window. Kept as a picker under the shared title bar
    /// rather than a `TabView` so the title bar, the hidden translation host and
    /// the window accessor stay mounted across a switch — tearing down the Apple
    /// Translation session on every tab change would be a real regression.
    enum MainTab: String, CaseIterable, Identifiable {
        case captions, prompt
        var id: String { rawValue }

        var chinese: String {
            switch self {
            case .captions: return "即時字幕"
            case .prompt: return "提示詞編譯"
            }
        }

        var english: String {
            switch self {
            case .captions: return "Live captions"
            case .prompt: return "Prompt composer"
            }
        }

        var icon: String {
            switch self {
            case .captions: return "captions.bubble.fill"
            case .prompt: return "wand.and.stars"
            }
        }

        /// One accent each, so the two modes are distinguishable by colour and
        /// not only by which outline is lit.
        var tint: Color {
            switch self {
            case .captions: return CaptionTheme.Palette.accentSystem
            case .prompt: return CaptionTheme.Palette.privacy
            }
        }

        var hint: String {
            switch self {
            case .captions: return "會議與影片的即時雙語字幕"
            case .prompt: return "把口述或打字的需求編譯成給編碼代理的提示詞"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBar
            // Always shown. Both panes are primary features, and a picker that
            // can vanish is a picker that can strand you on the pane it was the
            // only way out of.
            tabPicker
            switch tab {
            case .captions: captionsPane
            case .prompt: PromptComposerView(vm: vm, composer: vm.composer)
            }
        }
        .padding(20)
        // Both dimensions are set by the Prompt tab, which is the denser of the
        // two. The width now has to hold an editor column and a 300 pt inspector
        // beside it — at 680 the prompt preview was down to about 330 pt, which is
        // too narrow to read a rendered prompt in. The height came *down* when the
        // settings moved into that inspector and stopped contributing to it.
        .frame(minWidth: 940, minHeight: 620)
        .background(CaptionTheme.Palette.canvas)
        .preferredColorScheme(.dark)
        // Entering the tab starts the model download, the way pressing Start
        // does for a meeting. Without it the first compile silently blocks on
        // 2.3 GB with the UI showing only "compiling".
        .onChange(of: tab) { _, current in
            if current == .prompt { vm.prepareForPromptWork() }
        }
        // Hidden host for Apple's on-device translation session.
        .background(TranslationHostView(service: vm.translation))
        // Bind the main window so closing it stops the meeting + hides the overlay.
        .background(WindowAccessor { vm.bindMainWindow($0) })
        .sheet(isPresented: $showSettings) {
            SettingsView(
                settings: $vm.settings, vm: vm,
                initialPane: tab == .prompt ? .prompt : .captions
            )
        }
        .task {
            // Ask the Speech framework whether the built-in recognizer exists on
            // this machine before anything reads the answer. Until it has run,
            // `builtInAvailable` is false — which is the safe default: starting a
            // dictation on Nemotron and finding the built-in engine was available
            // costs nothing, while the reverse fails mid-session.
            await DictationEngineFactory.refreshAvailability()
            // Recovery first: its prompt defers the model-download prompt
            // (two simultaneous alerts on one view drop one of them).
            vm.checkForRecoverableSession()
            vm.preflightModels()
        }
        .alert("恢復上次會議？ Recover last meeting?", isPresented: $vm.showRecoveryPrompt) {
            Button("恢復 Recover") { vm.recoverIncompleteSession() }
            Button("捨棄 Discard", role: .destructive) { vm.discardIncompleteSession() }
        } message: {
            Text("The last meeting did not end cleanly. \(vm.recoverableCount) transcript "
                + "sentences are still recoverable — export them or generate a summary.")
        }
        .alert("下載模型？ Download models?", isPresented: $vm.showModelDownloadPrompt) {
            Button("下載 Download") { Task { await vm.downloadAllModels() } }
            Button("稍後 Later", role: .cancel) {}
        } message: {
            Text("""
            FlowTranslate 需要下載本機模型（一次性，之後完全離線可用）：
            • 語音辨識 ASR（所選語言）約 600 MB
            • Silero VAD 約 2 MB
            • Qwen 翻譯／摘要／提示詞模型 約 2.3 GB
            合計約 2.9 GB — 建議使用 Wi-Fi。
            All processing stays on this Mac.
            """)
        }
    }

    // MARK: - Panes

    /// The app's two modes, as two cards rather than a segmented control.
    ///
    /// A segmented picker reads as a setting for whatever is below it, not as
    /// the top-level navigation between two different features — and the two
    /// labels disagreed with each other, one bilingual and one not. Each card
    /// carries its own accent colour so which mode you are in is legible at a
    /// glance rather than from a one-pixel selection outline.
    private var tabPicker: some View {
        HStack(spacing: 10) {
            ForEach(MainTab.allCases) { item in
                tabCard(item)
            }
            Spacer()
        }
    }

    private func tabCard(_ item: MainTab) -> some View {
        let selected = tab == item
        return Button {
            tab = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.english).font(.system(size: 13, weight: .semibold))
                    Text(item.chinese).font(.system(size: 10))
                        .foregroundStyle(selected ? item.tint.opacity(0.9)
                                                  : CaptionTheme.Palette.inkTertiary)
                }
            }
            .foregroundStyle(selected ? item.tint : CaptionTheme.Palette.inkSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? item.tint.opacity(0.16) : CaptionTheme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? item.tint.opacity(0.55) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .help(item.hint)
    }

    /// The original single-window layout, unchanged — only lifted into its own
    /// property so the Prompt tab can sit beside it.
    private var captionsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            sourcesSection
            actionRow
            languageChip
            transcriptArea
            if !vm.summaryText.isEmpty { summaryArea }
            footer
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [CaptionTheme.Palette.accentSystem, CaptionTheme.Palette.privacy],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 24, height: 24)
                .overlay(Circle().fill(.white).frame(width: 9, height: 9))
            Text("Flow Translate").font(.system(size: 17, weight: .bold))
            Text("即時雙語字幕 Bilingual captions").font(.caption).foregroundStyle(CaptionTheme.Palette.inkTertiary)
            Spacer()
            statusPill
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").imageScale(.large)
                    .foregroundStyle(CaptionTheme.Palette.inkSecondary)
            }
            .buttonStyle(.borderless)
            .help("設定 Settings")
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if vm.isSummarizing {
            pill("整理摘要中… Summarizing", color: CaptionTheme.Palette.pin, spinner: true)
        } else {
            switch vm.asrState {
            case .listening: pill("聆聽中 Listening", color: CaptionTheme.Palette.mic, breathing: true)
            case .warming:   pill("模型載入中 Loading model", color: CaptionTheme.Palette.accentSystem, spinner: true)
            case .loading:   pill("準備中 Preparing", color: CaptionTheme.Palette.accentSystem, spinner: true)
            case .idle:      pill("待命 Idle", color: CaptionTheme.Palette.inkTertiary)
            }
        }
    }

    private func pill(_ text: String, color: Color, breathing: Bool = false, spinner: Bool = false) -> some View {
        HStack(spacing: 6) {
            if spinner {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 8, height: 8)
            } else if breathing {
                BreathingDot(color: color, size: 6).frame(width: 6, height: 6)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("音訊來源 SOURCES")
            HStack(spacing: 10) {
                SourceCard(title: "🎤 麥克風 Mic", color: CaptionTheme.Palette.mic,
                           on: vm.micEnabled, levels: vm.levels, level: \.mic) {
                    Task { await vm.toggleMic() }
                }
                SourceCard(title: "🔊 系統聲 System", color: CaptionTheme.Palette.accentSystem,
                           on: vm.systemEnabled, levels: vm.levels, level: \.system) {
                    Task { await vm.toggleSystem() }
                }
            }
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            mainButton
            HotkeyToggle(
                title: "浮動字幕 Overlay",
                keys: "⌃⌥C",
                isOn: $vm.overlayOn,
                help: "在任何 app 上方顯示懸浮字幕，隨時可用 ⌃⌥C 開關。"
            )
            Spacer()
            Button { Task { await vm.generateSummary() } } label: {
                Label("摘要 Summary", systemImage: "doc.text.magnifyingglass").font(.system(size: 12.5))
            }
            .buttonStyle(.bordered)
            .disabled(!vm.canSummarize)
            .help("會議結束後才能產生摘要 Summarize after the meeting ends")
            Button { vm.exportTranscript() } label: {
                Label("匯出 Export", systemImage: "square.and.arrow.down").font(.system(size: 12.5))
            }
            .buttonStyle(.bordered)
            .disabled(vm.lines.isEmpty)
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        switch vm.asrState {
        case .idle:
            Button { Task { await vm.startRecognition() } } label: {
                Label("開始 Start", systemImage: "play.fill").fontWeight(.semibold).frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(CaptionTheme.Palette.accentSystem)
            // Never start a meeting while a summary is generating (its model
            // unload would race the new meeting's translations) or during the
            // launch-time bulk download (duplicate ASR download).
            .disabled(vm.isSummarizing || vm.isDownloadingModels)
            .help(vm.isSummarizing ? "摘要產生中，完成後才能開始 Summary in progress"
                  : vm.isDownloadingModels ? "模型下載中 Models downloading" : "")
        case .loading:
            Button {} label: {
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("載入中 Loading") }.frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(true)
        case .warming, .listening:
            // Warming counts as an active meeting (audio already buffers), so the
            // user can stop it the same way.
            Button { Task { await vm.endMeeting() } } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                    Text("結束 Stop").fontWeight(.semibold)
                }.frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(CaptionTheme.Palette.stopRec)
        }
    }

    // MARK: - Language chip

    private var languageChip: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 8) {
                Text(vm.settings.scenario == .video ? "🎬 Video" : "👥 Meeting")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(CaptionTheme.Palette.inkPrimary)
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 12)
                Text("翻譯 Translate").font(.system(size: 12)).foregroundStyle(CaptionTheme.Palette.inkSecondary)
                Text(vm.settings.firstLanguage == "auto" ? "自動 Auto" : vm.settings.firstLanguage)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(CaptionTheme.Palette.inkPrimary)
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(CaptionTheme.Palette.inkTertiary)
                Text(vm.settings.secondCaptionEnabled ? vm.settings.secondLanguage.displayName : "關閉 Off")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(CaptionTheme.Palette.inkPrimary)
                Spacer()
                Text("變更 Change").font(.system(size: 11)).foregroundStyle(Color(hex: 0x7FB5FF))
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcript

    /// Live transcript sharing the overlay visual: source dot + English (primary) +
    /// timestamp + translation (secondary). Shows guidance when idle.
    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if vm.lines.isEmpty && vm.interimText.isEmpty {
                        idleGuidance
                    }
                    ForEach(vm.lines) { line in
                        TranscriptRow(line: line,
                                      showSpeakerSlot: vm.settings.diarizationEnabled)
                            .id(line.id)
                            .transition(.opacity)
                    }
                    if !vm.interimText.isEmpty {
                        InterimRow(text: vm.interimText, chinese: vm.interimChinese,
                                   source: vm.currentInterimSourceForUI,
                                   showSpeakerSlot: vm.settings.diarizationEnabled)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .animation(.easeOut(duration: 0.2), value: vm.lines.count)
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            .background(Color(hex: 0x161618), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.05), lineWidth: 1))
            .onChange(of: vm.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: vm.interimText) { _, _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }

    private var idleGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("開始即時字幕 Get started").font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(CaptionTheme.Palette.inkSecondary)
            guidanceStep("1", "選擇音訊來源（麥克風 / 系統聲）Pick a source")
            guidanceStep("2", "按「開始 Start」開始辨識與翻譯")
            guidanceStep("3", "開啟「浮動字幕 Overlay」或按 ⌃⌥C 顯示懸浮字幕")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func guidanceStep(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(CaptionTheme.Palette.accentSystem)
                .frame(width: 18, height: 18)
                .background(CaptionTheme.Palette.accentSystem.opacity(0.14), in: Circle())
            Text(text).font(.system(size: 12.5)).foregroundStyle(CaptionTheme.Palette.inkTertiary)
        }
    }

    // MARK: - Summary

    private var summaryArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("摘要 SUMMARY")
            ScrollView {
                Text(vm.summaryText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(CaptionTheme.Palette.inkPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 150)
        }
        .padding(12)
        .background(CaptionTheme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if !vm.translationStatus.isEmpty {
            Text(vm.translationStatus).font(.caption).foregroundStyle(CaptionTheme.Palette.inkSecondary)
        }
        if !vm.modelStatus.isEmpty {
            Text(vm.modelStatus).font(.caption).foregroundStyle(CaptionTheme.Palette.privacy)
        }
        // The message and, when a permission is what stopped it, the one control
        // that can change the answer. Nothing here opens System Settings on its
        // own — see `PermissionPane`.
        HStack(spacing: 8) {
            Text(vm.statusMessage).font(.callout).foregroundStyle(CaptionTheme.Palette.inkTertiary)
            if let pane = vm.statusAction {
                Button(PermissionPane.buttonTitle) { pane.open() }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(CaptionTheme.Palette.inkTertiary)
    }
}

// MARK: - Source card

private struct SourceCard: View {
    let title: String
    let color: Color
    let on: Bool
    /// Observed here rather than read from the parent, so a level change repaints
    /// this card alone instead of everything that observes the view model.
    @ObservedObject var levels: LevelMeters
    let level: KeyPath<LevelMeters, Float>
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(on ? color : CaptionTheme.Palette.inkTertiary).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(on ? CaptionTheme.Palette.inkPrimary : CaptionTheme.Palette.inkSecondary)
                        .fixedSize()
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { _ in action() }))
                    .labelsHidden().toggleStyle(.switch).tint(color)
            }
            VolumeMeter(level: levels[keyPath: level], color: color, active: on)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background((on ? color.opacity(0.08) : Color.white.opacity(0.03)),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(on ? color.opacity(0.3) : .white.opacity(0.06), lineWidth: 1))
    }
}

/// 7-segment live volume meter, lit proportionally to the (perceptually scaled) level.
private struct VolumeMeter: View {
    let level: Float
    let color: Color
    let active: Bool
    private let bars = 7

    var body: some View {
        let normalized = active ? min(max(Double(level).squareRoot() * 1.8, 0), 1) : 0
        let lit = Int((normalized * Double(bars)).rounded())
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < lit ? color : color.opacity(0.22))
                    .frame(height: 16 * heightFraction(i))
            }
        }
        .frame(height: 16, alignment: .bottom)
        .animation(.easeOut(duration: 0.12), value: lit)
    }

    private func heightFraction(_ i: Int) -> CGFloat {
        // A gentle wave so the meter reads as audio even at a glance.
        let pattern: [CGFloat] = [0.55, 0.9, 1.0, 0.7, 0.5, 0.35, 0.25]
        return pattern[i % pattern.count]
    }
}

// MARK: - Transcript rows

/// Leading geometry shared by every transcript row, so a finalized line, the
/// in-progress line and their translations all start at the same x — with or
/// without the speaker column. Each row hardcoding its own indent (it was 13 =
/// dot + gap) is what misaligned them the moment a speaker label appeared.
private enum TranscriptRowLayout {
    static let dotSize: CGFloat = 6
    static let gap: CGFloat = 7
    static let labelSize: CGFloat = 10
    /// Sized for the wider *half* of a wrapped name, not the whole name.
    ///
    /// The transcript window had room for `Claude Mango` on one line, but the
    /// column is reserved on every row here too, and 95 pt of it was going to a
    /// name that fits in 55 pt stacked. Both speaker columns now lay the name out
    /// the same way, which is also why they can share one measurement.
    @MainActor static var speakerWidth: CGFloat {
        CaptionTheme.speakerSlotWidth(labelSize: labelSize, style: .wrapped)
    }

    /// Where the caption text — and therefore its wrapped lines and translation
    /// — begins.
    @MainActor static func textIndent(speakerSlot: Bool) -> CGFloat {
        speakerSlot ? dotSize + gap + speakerWidth + gap : dotSize + gap
    }
}

private struct TranscriptRow: View {
    let line: CaptionLine
    /// Mirrors the diarization setting so the speaker column is reserved for
    /// every row, not just the ones that happen to carry a label.
    var showSpeakerSlot = false

    /// Reserve the speaker column when diarization is on — or whenever a label
    /// exists, so one can never be dropped because the setting is stale.
    private var reservesSpeakerSlot: Bool { showSpeakerSlot || line.speakerLabel != nil }

    /// Dot and speaker beside a column holding both caption lines — the same
    /// shape as the floating band, and for the same reason: a two-line speaker
    /// inside the first row pushes the translation down and opens a gap between
    /// the two captions.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptRowLayout.gap) {
            Circle().fill(CaptionTheme.Palette.sourceDot(line.source))
                .frame(width: TranscriptRowLayout.dotSize, height: TranscriptRowLayout.dotSize)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
            Group {
                if reservesSpeakerSlot {
                    // Fixed-width column: the sentence starts at the same x with
                    // or without a label, and its wrapped lines stay inside the
                    // text column instead of running back under the speaker.
                    Text(SpeakerName.wrapping(line.speakerLabel ?? ""))
                        .font(.system(size: TranscriptRowLayout.labelSize, weight: .bold))
                        .foregroundStyle(CaptionTheme.Palette.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        // Same reasoning as the floating band: a truncated
                        // speaker name is worse than a column that widens for it,
                        // because two names can truncate to the same prefix.
                        // Both axes: a height proposed by the row is a one-line
                        // height, and the label needs two.
                        .fixedSize()
                        .frame(minWidth: TranscriptRowLayout.speakerWidth, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: TranscriptRowLayout.gap) {
                    Text(line.english)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(CaptionTheme.Palette.inkPrimary)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(Self.clock(line.timestamp))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                }
                if let zh = line.chinese, !zh.isEmpty {
                    Text(zh)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(hex: 0x9DA3AE))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shared cached formatter — building a DateFormatter is expensive and this
    /// runs for every visible transcript row on every re-render (up to 500 rows).
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func clock(_ d: Date) -> String {
        clockFormatter.string(from: d)
    }
}

private struct InterimRow: View {
    let text: String
    let chinese: String
    let source: AudioSourceType
    /// Reserve the same speaker column as the finalized rows even though an
    /// in-progress line never has a label yet — otherwise the live line sits a
    /// whole column to the left of everything above it.
    var showSpeakerSlot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: TranscriptRowLayout.gap) {
                Circle().fill(CaptionTheme.Palette.sourceDot(source))
                    .frame(width: TranscriptRowLayout.dotSize, height: TranscriptRowLayout.dotSize)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
                if showSpeakerSlot {
                    Color.clear.frame(width: TranscriptRowLayout.speakerWidth, height: 1)
                }
                Text(text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(CaptionTheme.Palette.inkPrimary.opacity(0.66))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 1).offset(y: 2)
                    }
            }
            if !chinese.isEmpty {
                Text(chinese)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: 0x9DA3AE).opacity(0.7))
                    .padding(.leading, TranscriptRowLayout.textIndent(speakerSlot: showSpeakerSlot))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(0.9)
    }
}

/// Hands the hosting `NSWindow` back to the view model once the view is in a window.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

#Preview {
    ContentView(vm: CaptureViewModel())
}
