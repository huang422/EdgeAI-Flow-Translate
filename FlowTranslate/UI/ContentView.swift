import SwiftUI

struct ContentView: View {
    @StateObject private var vm = CaptureViewModel()
    @State private var showSettings = false

    private static let bottomAnchor = "TRANSCRIPT_BOTTOM"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sources
            controls
            captionArea
            if !vm.summaryText.isEmpty { summaryArea }
            if !vm.translationStatus.isEmpty {
                Text(vm.translationStatus).font(.caption).foregroundStyle(.blue)
            }
            if !vm.modelStatus.isEmpty {
                Text(vm.modelStatus).font(.caption).foregroundStyle(.purple)
            }
            Text(vm.statusMessage).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
        // Hidden host for Apple's on-device translation session.
        .background(TranslationHostView(service: vm.translation))
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $vm.settings)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Flow Translate").font(.largeTitle).bold()
                Text("Local real-time bilingual captions · Nemotron ASR + on-device translation")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape").imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help("設定 Settings")
        }
    }

    private var sources: some View {
        HStack(spacing: 12) {
            sourceToggle(title: "麥克風 Mic", on: vm.micEnabled, level: vm.micLevel) { Task { await vm.toggleMic() } }
            sourceToggle(title: "系統聲 System", on: vm.systemEnabled, level: vm.systemLevel) { Task { await vm.toggleSystem() } }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            switch vm.asrState {
            case .idle:
                Button("開始會議 Start") { Task { await vm.startRecognition() } }
                    .buttonStyle(.borderedProminent)
            case .loading:
                ProgressView().controlSize(.small); Text("Loading model…")
            case .listening:
                Button("結束會議 End", role: .destructive) { Task { await vm.endMeeting() } }
                Label("Listening", systemImage: "waveform").foregroundStyle(.green)
            }
            Toggle("浮動字幕 Overlay (⌃⌥C)", isOn: Binding(get: { vm.overlayOn }, set: { _ in vm.toggleOverlay() }))
                .toggleStyle(.switch)
                .help("快捷鍵 ⌃⌥C 可隨時開關浮動字幕")
            Button("匯出 Export") { vm.exportTranscript() }
                .disabled(vm.lines.isEmpty)
        }
    }

    /// Live transcript: every finalized sentence as its own paragraph (English +
    /// translation), plus the current interim line, auto-scrolling to the latest.
    private var captionArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.english)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            if let zh = line.chinese, !zh.isEmpty {
                                Text(zh)
                                    .foregroundStyle(.blue)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(line.id)
                        .transition(.opacity)   // new sentences fade in
                    }
                    if !vm.interimText.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vm.interimText)
                                .foregroundStyle(.secondary).italic()
                            if !vm.interimChinese.isEmpty {
                                Text(vm.interimChinese)
                                    .foregroundStyle(.blue.opacity(0.7)).italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Bottom anchor for auto-scroll.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .animation(.easeOut(duration: 0.2), value: vm.lines.count)
            }
            .frame(minHeight: 240, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: vm.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: vm.interimText) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var summaryArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("會議摘要 Summary").font(.headline)
            ScrollView {
                Text(vm.summaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 150)
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func sourceToggle(title: String, on: Bool, level: Float, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(on ? "停止 Stop" : "開始 Start", action: action)
            }
            // Perceptual (sqrt) scaling so quieter mic input still moves the bar.
            ProgressView(value: Double(min(max(level.squareRoot() * 1.8, 0), 1))).frame(width: 150)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ContentView()
}
