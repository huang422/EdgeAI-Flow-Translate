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

    private static let bottomAnchor = "TRANSCRIPT_BOTTOM"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBar
            sourcesSection
            actionRow
            languageChip
            transcriptArea
            if !vm.summaryText.isEmpty { summaryArea }
            footer
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 620)
        .background(CaptionTheme.Palette.canvas)
        .preferredColorScheme(.dark)
        // Hidden host for Apple's on-device translation session.
        .background(TranslationHostView(service: vm.translation))
        // Bind the main window so closing it stops the meeting + hides the overlay.
        .background(WindowAccessor { vm.bindMainWindow($0) })
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $vm.settings)
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
            case .loading:   pill("載入中 Loading", color: CaptionTheme.Palette.accentSystem, spinner: true)
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
                           on: vm.micEnabled, level: vm.micLevel) { Task { await vm.toggleMic() } }
                SourceCard(title: "🔊 系統聲 System", color: CaptionTheme.Palette.accentSystem,
                           on: vm.systemEnabled, level: vm.systemLevel) { Task { await vm.toggleSystem() } }
            }
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            mainButton
            HStack(spacing: 8) {
                Toggle("", isOn: $vm.overlayOn)
                    .labelsHidden().toggleStyle(.switch).tint(CaptionTheme.Palette.accentSystem)
                Text("浮動字幕 Overlay").font(.system(size: 12.5)).foregroundStyle(CaptionTheme.Palette.inkSecondary)
                Text("⌃⌥C").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(CaptionTheme.Palette.inkTertiary)
            }
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
        case .loading:
            Button {} label: {
                HStack(spacing: 7) { ProgressView().controlSize(.small); Text("載入中 Loading") }.frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(true)
        case .listening:
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
                Text("翻譯").font(.system(size: 12)).foregroundStyle(CaptionTheme.Palette.inkSecondary)
                Text(vm.settings.firstLanguage == "auto" ? "自動偵測" : vm.settings.firstLanguage)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(CaptionTheme.Palette.inkPrimary)
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(CaptionTheme.Palette.inkTertiary)
                Text(vm.settings.secondCaptionEnabled ? vm.settings.secondLanguage.displayName : "關閉")
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
                        TranscriptRow(line: line).id(line.id)
                            .transition(.opacity)
                    }
                    if !vm.interimText.isEmpty {
                        InterimRow(text: vm.interimText, chinese: vm.interimChinese, source: vm.currentInterimSourceForUI)
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
        Text(vm.statusMessage).font(.callout).foregroundStyle(CaptionTheme.Palette.inkTertiary)
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
    let level: Float
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
            VolumeMeter(level: level, color: color, active: on)
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

private struct TranscriptRow: View {
    let line: CaptionLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(CaptionTheme.Palette.sourceDot(line.source)).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
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
                    .padding(.leading, 13)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

private struct InterimRow: View {
    let text: String
    let chinese: String
    let source: AudioSourceType

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(CaptionTheme.Palette.sourceDot(source)).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
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
                    .padding(.leading, 13)
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
