import AppKit
import SwiftUI
import FlowTranslateCore

/// The Prompt tab: capture a request by voice or keyboard, compile it into a
/// token-efficient prompt, and install it wherever Claude Code will read it.
struct PromptComposerView: View {
    /// Owns `settings` (project folder, output language) — a separate
    /// `ObservableObject` from the composer, so both have to be observed
    /// explicitly. Reaching the composer through `vm` alone would compile but
    /// never redraw, because a computed property does not subscribe.
    @ObservedObject var vm: CaptureViewModel
    @ObservedObject var composer: PromptComposerViewModel
    @State private var showRulebook = false
    @State private var installMessage: String?
    /// The three dictation languages, with the built-in engine's per-language
    /// "already downloaded" flags filled in once it has been asked. Seeded with
    /// the plain list so the picker is never momentarily empty.
    @State private var dictationLanguages = DictationLanguage.options

    /// Names the engine behind the list, and says what a download marker means.
    ///
    /// The two engines do not offer the same rows: only Nemotron can do 混說, so
    /// only Nemotron shows it. Saying which engine is talking is what stops the
    /// row count changing under the user for no visible reason.
    private var dictationLanguageNote: String {
        DictationEngineFactory.resolved(vm.settings) == .appleSpeech
            ? "Mac 內建辨識器（單一語言，無混說）· ⬇ = 系統語言資產尚未下載"
            : "Nemotron · 混說 uses the multilingual weights"
    }

    /// Ask the engine which languages it offers, and keep the stored choice valid.
    private func refreshDictationLanguages() async {
        let languages = await DictationEngineFactory.availableLanguages(for: vm.settings)
        dictationLanguages = languages
        guard !languages.contains(where: { $0.code == vm.settings.promptDictationLanguage })
        else { return }
        // A Picker whose selection matches no tag renders blank and cannot be
        // changed back, so a value the current engine does not offer has to land
        // somewhere. Two ways to get here: a `zh-CN` from the builds where the
        // engines had separate code sets, and a `混說` carried to the built-in
        // recognizer, which has no such mode.
        //
        // Prefer 混說 when it is on offer — it is the app's default and the one
        // choice that is right for any speaker. Otherwise take the first language
        // the recognizer already has installed, because a language it would have
        // to download first is a worse guess than one the user has set up.
        if languages.contains(where: { $0.code == "auto" }) {
            vm.settings.promptDictationLanguage = "auto"
        } else if let ready = languages.first(where: \.installed) ?? languages.first {
            vm.settings.promptDictationLanguage = ready.code
        }
    }

    /// Editor on the left, inspector on the right.
    ///
    /// Two columns rather than one, so the controls touched once a week are not
    /// sitting between the request and the button that acts on it:
    /// the left column is the *work* — write a request, act on it, read the
    /// result — and it takes all the height, because the two things in it that
    /// vary are the two that need it. The right column is *configuration*, at a
    /// fixed width, and it no longer contributes to the page height at all.
    ///
    /// Neither column scrolls as a whole. The request box and the prompt preview
    /// scroll inside themselves; the inspector scrolls inside itself when the
    /// window is short.
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            editorColumn
            inspectorColumn
                .frame(width: Self.inspectorWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showRulebook) {
            RulebookEditorView(rulebook: Binding(
                get: { composer.rulebook },
                set: { composer.rulebook = $0 }
            ))
        }
        .task { await refreshDictationLanguages() }
        .task(id: vm.settings.promptDictationEngine) { await refreshDictationLanguages() }
    }

    /// Wide enough for a segmented control of four options plus its explanation
    /// at a readable measure, and narrow enough to leave the prompt preview the
    /// majority of a default-width window.
    private static let inspectorWidth: CGFloat = 300

    // MARK: - Editor column

    /// What you do, top to bottom, in the order you do it.
    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputSection
                .frame(maxHeight: composer.artifact == nil ? .infinity : Self.settledInputHeight)
            // Directly under the request. These four act on the text immediately
            // above them and are the most-used controls on the page.
            actionRow
            if let message = installMessage { messageRow(message) }
            if let comparison = composer.comparison { savingsRow(comparison) }
            if !composer.findings.isEmpty { lintSection }
            if composer.artifact != nil { outputSection }
            if !composer.statusMessage.isEmpty { statusRow }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Syncing happens before the first compile, so its result needs somewhere to
    /// appear that does not depend on there being one. Wrapping rather than
    /// truncating: a file path is the whole content of this message, and the
    /// middle of a path is exactly the part you need.
    private func messageRow(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(CaptionTheme.Palette.inkSecondary)
    }

    // MARK: - Inspector column

    /// Everything that changes what Compile produces, out of the way of using it.
    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsGroup
                syncHint
                modelStateRow
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: - Input

    /// What the request box shrinks to once there is a compiled prompt to read.
    /// Roughly six lines at 13 pt — enough to see a whole spoken request without
    /// scrolling, and small enough to leave the preview the rest of the page.
    private static let settledInputHeight: CGFloat = 130

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("需求 Request").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CaptionTheme.Palette.inkSecondary)
                Spacer()
                // Typing stays available during a meeting; only the GPU-bound
                // actions are gated.
                if let reason = composer.blockedReason {
                    Text(reason).font(.caption).foregroundStyle(CaptionTheme.Palette.pin)
                }
            }

            // `TextEditor` scrolls itself, so a flexible frame gives it the
            // leftover page height and keeps long requests inside their own box
            // instead of pushing the buttons off the bottom of the window.
            TextEditor(text: Binding(
                get: { composer.inputText },
                set: { composer.inputText = $0; composer.noteManualEdit() }
            ))
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 88, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(CaptionTheme.Palette.surface))
            .overlay(alignment: .topLeading) {
                if composer.inputText.isEmpty {
                    Text("Speak or type what you want Claude Code or Codex to do.")
                        .font(.system(size: 12))
                        .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            if !composer.interimText.isEmpty {
                Text(composer.interimText)
                    .font(.system(size: 12))
                    .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Settings

    /// Label above control, one setting per row.
    ///
    /// A `Grid` with the label beside the control was right at full width and is
    /// wrong at 300 pt: the trailing-aligned label column ate a third of the row
    /// and left the segmented controls squeezed, and the explanations under them
    /// wrapped to four lines. Stacking puts every control and every label on the
    /// same left edge, which is also the alignment the buttons in the left column
    /// use, so nothing on the page starts at a different x.
    private var settingsGroup: some View {
        VStack(alignment: .leading, spacing: 14) {
            setting("目標代理 Agent",
                    help: "Claude 輸出 XML 標籤，Codex 輸出 Markdown — 各自官方文件建議的寫法") {
                Picker("", selection: Binding(
                    get: { vm.settings.promptLayout },
                    set: { vm.settings.promptLayout = $0 }
                )) {
                    ForEach(PromptLayout.allCases) { Text($0.shortName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            // The two languages are different questions and were adjacent and
            // unlabelled, which read as one setting duplicated. This one is what
            // the prompt comes out in; the next is what you speak.
            setting("輸出語言 Output",
                    help: "編譯出來的 prompt 用哪個語言。英文可套用全部壓縮技術；繁中只套用安全技術") {
                Picker("", selection: Binding(
                    get: { vm.settings.promptOutputLanguage },
                    set: { vm.settings.promptOutputLanguage = $0 }
                )) {
                    ForEach(PromptOutputLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            // The same three rows for both engines — the two languages this app
            // is written for, plus mixed speech. See
            // `DictationEngineFactory.availableLanguages` for why the built-in
            // recognizer's much longer locale list is deliberately not offered
            // here. Only the ⬇ markers are refreshed when the engine changes.
            setting("口述語言 Dictation", note: dictationLanguageNote) {
                Picker("", selection: Binding(
                    get: { vm.settings.promptDictationLanguage },
                    set: { vm.settings.promptDictationLanguage = $0 }
                )) {
                    ForEach(dictationLanguages) { language in
                        // The tick says the assets are already on disk. Without it
                        // the first dictation in a new language is an unexplained
                        // wait while the system fetches them.
                        Text(language.installed ? language.displayName
                                                : "\(language.displayName) ⬇")
                            .tag(language.code)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Separate from the compression profile, which shortens the
            // *wording*: this decides which blocks exist at all.
            setting("輸出詳細度 Detail", note: vm.settings.promptDetailLevel.explanation) {
                Picker("", selection: Binding(
                    get: { vm.settings.promptDetailLevel },
                    set: { vm.settings.promptDetailLevel = $0 }
                )) {
                    ForEach(PromptDetailLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(sectionsIncluded)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The explanation is shown, not hidden in a tooltip: the options
            // differ in ways their names cannot carry.
            setting("約束寫法 Constraints", note: vm.settings.promptSymbolMode.explanation) {
                Picker("", selection: Binding(
                    get: { vm.settings.promptSymbolMode },
                    set: { vm.settings.promptSymbolMode = $0 }
                )) {
                    ForEach(PromptSymbolMode.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                if vm.settings.promptSymbolMode.requiresSyncedRulebook,
                   vm.settings.promptTargetProjectPath == nil {
                    warning("尚未選擇專案，此模式會退回完整寫出規則。選好資料夾並同步後才會用符號。")
                }
            }

            setting("專案 Project") {
                Button {
                    if let picked = PromptArtifactWriter.chooseProjectFolder(
                        startingAt: vm.settings.promptTargetProjectPath
                    ) {
                        vm.settings.promptTargetProjectPath = picked
                    }
                } label: {
                    Label(
                        vm.settings.promptTargetProjectPath.map {
                            URL(fileURLWithPath: $0).lastPathComponent
                        } ?? "選擇資料夾 Choose…",
                        systemImage: "folder"
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Disabled until there is somewhere to write to, rather than
                // opening a folder picker as a side effect — "choose a project"
                // and "sync" are two actions.
                Button {
                    syncRulebook()
                } label: {
                    Label("同步規則本 Sync rules", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(vm.settings.promptTargetProjectPath == nil)
                .help(vm.settings.promptTargetProjectPath == nil
                    ? "請先選擇專案資料夾 Choose a project folder first"
                    : "把規則寫進專案，讓 Claude 每個 session 都讀得到。")

                Button {
                    showRulebook = true
                } label: {
                    Label("編輯規則本 Edit rulebook", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        }
        .font(.system(size: 11))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(CaptionTheme.Palette.surface.opacity(0.5)))
    }

    /// One labelled setting: title, control(s), and an optional explanation.
    ///
    /// A single builder so every row has the same label style, the same spacing
    /// and the same left edge — the thing six hand-rolled `GridRow`s kept
    /// drifting away from.
    @ViewBuilder
    private func setting<Content: View>(
        _ title: String,
        note: String? = nil,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CaptionTheme.Palette.inkSecondary)
            content()
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(CaptionTheme.Palette.pin)
    }

    /// The actual tag names this level will print, so the choice is checkable
    /// rather than a word to be trusted. Named in the layout's own vocabulary —
    /// `<task>` for Claude, `## Goal` for Codex — because those are the strings
    /// the user will see in the output.
    ///
    /// Every listed section is still conditional on having content: a request
    /// that named no file prints no `<files>` at either level. This says what is
    /// *allowed*, not what will appear.
    private var sectionsIncluded: String {
        let layout = vm.settings.promptLayout
        let names = PromptComposerView.sectionOrder
            .filter { vm.settings.promptDetailLevel.includes($0.kind) }
            .map { layout == .claudeXML ? "<\($0.xml)>" : "## \($0.markdown)" }
        return names.joined(separator: layout == .claudeXML ? " " : " · ")
    }

    /// Render order, with the tag each section prints under.
    private static let sectionOrder: [(kind: PromptSectionKind, xml: String, markdown: String)] = [
        (.question, "question", "Question"),
        (.task, "task", "Goal"),
        (.context, "context", "Context"),
        (.deliverables, "output", "Output"),
        (.constraints, "constraints", "Constraints"),
        (.scopeExclusions, "out_of_scope", "Out of scope"),
        (.acceptance, "done_when", "Done when"),
        (.failureCases, "risks", "Known risks"),
        (.references, "files", "Files"),
        (.tools, "tools", "Suggested tools"),
    ]

    // MARK: - Actions

    /// One primary action, the rest secondary.
    ///
    /// Every label reads `中文 English`, the same rule the rest of the app
    /// follows — the row previously mixed bilingual labels with Chinese-only
    /// ones, so it read as two features bolted together.
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    if composer.phase == .listening || composer.phase == .warming {
                        await composer.stopDictation()
                    } else {
                        await composer.startDictation()
                    }
                }
            } label: {
                Label(recordLabel, systemImage: recordIcon).frame(minWidth: 74)
            }
            // Enabled only when it does something: idle and able to record, or
            // already listening so the click stops it. The old condition left it
            // live during compile and tidy, where the click is inert — and
            // `.finishing` belongs on the inert side too, since the drain is
            // already committed.
            .disabled(!composer.canRecord && composer.phase != .listening
                      && composer.phase != .warming)

            Button {
                composer.compile()
            } label: {
                Label(compileLabel, systemImage: "wand.and.stars").frame(minWidth: 82)
            }
            .buttonStyle(.borderedProminent)
            // Blocked while the model is still downloading. Compiling then does
            // work — it queues behind the download — but the button would sit
            // silent for minutes, which is indistinguishable from a hang.
            .disabled(!composer.canCompile || isModelDownloading)
            .help(modelStateHelp)

            Button {
                composer.tidy()
            } label: {
                Label("整理 Tidy", systemImage: "text.badge.checkmark")
            }
            .help("Fixes typos, mangled terms and punctuation, and re-splits sentences — for typed input as well as dictated")
            // Tidy is a model pass over the passage, so it waits on the same
            // download Compile does.
            .disabled(!composer.canCompile || isModelDownloading)

            Button {
                composer.clear()
            } label: {
                Label("清除 Clear", systemImage: "trash")
            }
            .disabled(composer.inputText.isEmpty && composer.artifact == nil)

            Spacer()

            // The same control the captions page puts on its own action row, in
            // the same place: this is one of the app's two headline features.
            HotkeyToggle(
                title: "口述快捷鍵 Dictate",
                keys: "⌃⌥Space",
                isOn: Binding(
                    get: { vm.settings.promptHotkeyEnabled },
                    set: { vm.setDictationHotkey($0) }
                ),
                help: "在任何 app 按 ⌃⌥Space 口述，結果直接插入游標位置（插入 "
                    + "\(vm.settings.promptQuickInsertMode.displayName)）。"
            )
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Nudges towards syncing, but only when the prompt would actually benefit.
    ///
    /// Keyed on `unresolvedSymbols` — the symbols the compressor actually
    /// recognised in *this* request and the project cannot define — rather than
    /// on `usedSymbols` being empty, which is also true of every prompt whose
    /// constraints matched no rule at all and where syncing would change nothing.
    ///
    /// Naming the symbols is the other half. "Your constraints are written out in
    /// full" says nothing checkable; "NO_DEPS, TEST_PASS would shrink" does.
    @ViewBuilder private var syncHint: some View {
        if let artifact = composer.artifact, !artifact.unresolvedSymbols.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text("\(artifact.unresolvedSymbols.joined(separator: ", ")) could be shortened "
                    + "to symbols, but this project has not defined them yet. Sync the rulebook "
                    + "to enable it.")
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("同步規則本 Sync") { syncRulebook() }.font(.caption2)
            }
            .foregroundStyle(CaptionTheme.Palette.inkTertiary)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(CaptionTheme.Palette.surface))
        }
    }



    private var recordLabel: String {
        switch composer.phase {
        case .warming: return "載入中 Warming…"
        case .listening: return "停止 Stop"
        // The drain that keeps the last sentence. Named rather than left looking
        // idle, because it is the half-second between the click and the tidy and
        // an unlabelled gap there reads as the button not having worked.
        case .finishing: return "收尾中 Finishing…"
        case let .tidying(fraction): return "整理中 \(Int(fraction * 100))%"
        default: return "口述 Dictate"
        }
    }

    private var recordIcon: String {
        composer.phase == .listening ? "stop.circle.fill" : "mic.fill"
    }

    private var compileLabel: String {
        if case let .compiling(tokens) = composer.phase {
            return tokens > 0 ? "編譯中 \(tokens)" : "編譯中…"
        }
        // Says what the press will actually do. The first compile after opening
        // the app also loads ~2.3 GB into memory, which is several seconds of
        // nothing happening if the button just says "Compile".
        if case .onDisk = vm.promptModelState { return "載入並編譯 Load & compile" }
        return "編譯 Compile"
    }

    private var isModelDownloading: Bool {
        if case .downloading = vm.promptModelState { return true }
        return false
    }

    /// One line on the shared model, shown only when it is not simply ready.
    private var modelStateHelp: String {
        switch vm.promptModelState {
        case .loaded: return "模型已在記憶體中 Model is resident"
        case .onDisk: return "第一次編譯會先把模型載入記憶體（數秒）"
        case let .downloading(fraction):
            let pct = fraction.map { " \(Int($0 * 100))%" } ?? ""
            return "正在下載模型\(pct) Downloading the model — 編譯會在下載完成後才可用"
        case let .unavailable(reason): return reason
        }
    }

    @ViewBuilder private var modelStateRow: some View {
        if vm.promptModelState != .loaded {
            HStack(spacing: 6) {
                if isModelDownloading {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "cpu").font(.system(size: 10))
                }
                Text(modelStateHelp).font(.caption2)
                Spacer()
            }
            .foregroundStyle(CaptionTheme.Palette.inkTertiary)
        }
    }

    // MARK: - Savings

    private func savingsRow(_ comparison: TokenComparison) -> some View {
        HStack(spacing: 14) {
            Label(comparison.summary, systemImage: "arrow.down.right.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(comparison.saved >= 0 ? CaptionTheme.Palette.mic : CaptionTheme.Palette.pin)

            if let artifact = composer.artifact, !artifact.usedSymbols.isEmpty {
                // Per session, not per prompt. `.claude/rules/` loads at every
                // session start, so this is a standing tax on every
                // conversation in the project — folding it into the per-prompt
                // saving would misrepresent both numbers.
                Text("規則本 ≈\(composer.rulebookTokenCost) tokens × 每個 session"
                    + "（\(composer.rulebookLineCount) 行）")
                    .font(.caption)
                    .foregroundStyle(composer.rulebookIsOversized
                        ? CaptionTheme.Palette.pin : CaptionTheme.Palette.inkTertiary)
            }
            Spacer()
            // Says which counter produced the number. A real BPE count is exact
            // for the local model; the heuristic is not, and Claude's own
            // tokenizer is not published at all, so labelling every number the
            // same way would claim precision that does not exist.
            Text(comparison.source.displayNote)
                .font(.caption2)
                .foregroundStyle(CaptionTheme.Palette.inkTertiary)
        }
    }

    // MARK: - Lint

    private var lintSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("需要你決定 Needs your call").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CaptionTheme.Palette.inkSecondary)
                Spacer()
            }
            // Bounded and self-scrolling: a contradictory-constraint pass can
            // produce one finding per pair, and an unbounded list pushed the
            // output preview off the window entirely.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(composer.findings) { finding in
                        findingRow(finding)
                    }
                }
            }
            .frame(maxHeight: composer.findings.count > 2 ? 132 : .infinity)
            .fixedSize(horizontal: false, vertical: composer.findings.count <= 2)
        }
    }

    private func findingRow(_ finding: LintFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.isAutoFixable ? "wrench.adjustable" : "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(finding.isAutoFixable
                    ? CaptionTheme.Palette.accentSystem : CaptionTheme.Palette.inkTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.message).font(.system(size: 11))
                    .foregroundStyle(CaptionTheme.Palette.inkPrimary)
                if let offending = finding.offending {
                    Text(offending).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if finding.isAutoFixable {
                Button("套用 Apply") { composer.apply(finding) }.font(.caption2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(CaptionTheme.Palette.surface))
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let artifact = composer.artifact {
                // Flexible rather than a fixed 200pt: the preview takes whatever
                // the page has left, so a taller window shows more of the prompt
                // instead of the same short slot with more empty space under it.
                ScrollView {
                    Text(artifact.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CaptionTheme.Palette.inkPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(CaptionTheme.Palette.surface))

                // Outside the scroll view, so Copy and Install stay put while the
                // prompt is being read.
                outputActions(artifact)
            }
        }
    }

    private func outputActions(_ artifact: PromptArtifact) -> some View {
        HStack(spacing: 10) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(artifact.content, forType: .string)
                installMessage = "已複製 Copied"
            } label: {
                Label("複製 Copy", systemImage: "doc.on.doc")
            }

            Button {
                export(artifact)
            } label: {
                Label("另存 Save", systemImage: "square.and.arrow.down")
            }

            // Rendered on demand for the chosen surface, rather than keyed on
            // persistent state: a skill and a slash command are two things to do
            // with one compiled prompt.
            Menu {
                Button("Skill — .claude/skills") { install(as: .skill) }
                Button("Slash command — .claude/commands") { install(as: .command) }
            } label: {
                Label("安裝 Install", systemImage: "folder.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()


        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    // MARK: - File actions

    private func export(_ artifact: PromptArtifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "prompt.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try artifact.content.write(to: url, atomically: true, encoding: .utf8)
            installMessage = "已儲存 Saved to \(url.lastPathComponent)"
        } catch {
            installMessage = "儲存失敗 Save failed: \(error.localizedDescription)"
        }
    }

    /// Render the current IR for one installable surface and write it.
    ///
    /// The kind is passed in rather than read from persistent state: a skill and
    /// a slash command are two different things to *do* with one compiled
    /// prompt, not two modes the composer sits in.
    private func install(as kind: PromptArtifactKind) {
        // Both of these say why they refused: a silent `return` makes Install
        // look broken when there is no folder chosen, or nothing compiled yet.
        guard let root = resolveProjectRoot() else {
            installMessage = "請先選擇專案資料夾 Choose a project folder first"
            return
        }
        guard let artifact = composer.artifact(as: kind) else {
            installMessage = "請先按「編譯」 Compile something first"
            return
        }
        do {
            let path = try PromptArtifactWriter.write(artifact, toProjectAt: root)
            // The full path, not just the relative one: "where did it go" is the
            // question this message exists to answer.
            installMessage = "已寫入 Installed → \(path)"
            composer.invalidateSyncedSymbols()
            composer.render()
        } catch {
            installMessage = "寫入失敗 Install failed: \(error.localizedDescription)"
        }
    }

    private func syncRulebook() {
        guard let root = resolveProjectRoot() else {
            installMessage = "請先選擇專案資料夾 Choose a project folder first"
            return
        }
        do {
            // Follows the target agent. The two ecosystems do not read each
            // other's file — Claude Code loads `.claude/rules/` and ignores
            // AGENTS.md; Codex, Cursor and Aider read AGENTS.md and know nothing
            // about `.claude/` — so "which agent" already answers "which file".
            // A second switch for the same question meant picking Claude on the
            // page and writing AGENTS.md anyway.
            //
            // Only the selected categories are installed: the file loads at every
            // session start, so a category this project never uses is a standing
            // cost on every conversation in it.
            let report = try PromptArtifactWriter.syncRules(
                composer.activeRulebook,
                language: vm.settings.promptOutputLanguage,
                backends: [vm.settings.promptLayout.backend],
                toProjectAt: root,
                // One agent selected, one file written. Bridging two ecosystems
                // is a deliberate decision, not a side effect of syncing.
                createClaudeBridge: false
            )
            installMessage = "已寫入 Wrote → " + report.written
                .map { root + "/" + $0 }.joined(separator: " · ")
            // Syncing exists to make bare symbols honest, so it selects them.
            // Leaving the mode alone meant the button's whole purpose was
            // achieved and nothing about the output changed — the user had to
            // know to go and flip a second control to collect the benefit.
            //
            // Only from a mode that was already asking for symbols or was the
            // default; someone who deliberately chose to keep their own wording
            // has said something, and a sync is not a reason to overrule it.
            if vm.settings.promptSymbolMode == .symbolsWithLegend {
                vm.settings.promptSymbolMode = .symbolsAssumeRulebook
                installMessage? += " · 已切換為純符號 Switched to symbols"
            }
            // Invalidate BEFORE re-rendering. The cached symbol set is what
            // decides whether bare symbols are safe, and the sync just changed
            // the answer — rendering against the stale cache kept downgrading to
            // the legend mode forever, defeating the cheapest mode and
            // contradicting the comment on the next line.
            composer.invalidateSyncedSymbols()
            // Re-render: with the rules on disk, bare symbols become safe.
            composer.render()
        } catch {
            installMessage = "同步失敗 Sync failed: \(error.localizedDescription)"
        }
    }



    /// Use the remembered project folder, asking for one the first time.
    private func resolveProjectRoot() -> String? {
        if let existing = vm.settings.promptTargetProjectPath, !existing.isEmpty { return existing }
        guard let picked = PromptArtifactWriter.chooseProjectFolder(startingAt: nil) else { return nil }
        vm.settings.promptTargetProjectPath = picked
        return picked
    }

    private var statusRow: some View {
        Text(composer.statusMessage)
            .font(.caption)
            .foregroundStyle(CaptionTheme.Palette.pin)
    }
}

