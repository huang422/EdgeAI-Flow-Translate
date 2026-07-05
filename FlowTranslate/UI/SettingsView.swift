import SwiftUI
import FlowTranslateCore

/// Caption / language settings (US3) + overlay presentation (redesign §4). Bound to
/// the live `CaptionSettings`, applied immediately and persisted.
struct SettingsView: View {
    @Binding var settings: CaptionSettings
    @ObservedObject var vm: CaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false

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

    var body: some View {
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
                    Text("自動偵測 / 混合語言 Auto").tag("auto")
                    ForEach(SupportedASRLanguages.all) { locale in
                        Text("\(locale.displayName) (\(locale.code))").tag(locale.code)
                    }
                }
                Picker("延遲層級 Latency", selection: $settings.asrTier) {
                    Text("Lowest 560ms").tag("560ms")
                    Text("Balanced 1120ms").tag("1120ms")
                }
                .pickerStyle(.segmented)
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

                Picker(selection: $settings.interimStyle) {
                    Text("Dim + caret").tag(InterimStyle.dimmedWithCaret)
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
            Section("維護 Maintenance") {
                VStack(alignment: .leading, spacing: 3) {
                    Button("重設權限 Reset permissions") {
                        Task { await vm.resetPrivacyPermissions() }
                        dismiss()
                    }
                    Text("Clears this app's Microphone / Screen Recording privacy entries. Use after replacing the app when the toggles look ON but capture fails.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("解除安裝 Uninstall") { confirmUninstall = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .confirmationDialog("解除安裝 FlowTranslate？", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("移到垃圾桶並刪除模型 Uninstall") { vm.uninstall() }
            Button("取消 Cancel", role: .cancel) {}
        } message: {
            Text("移除下載的模型、逐字稿、設定與隱私權限記錄，並把 App 移到垃圾桶後結束。Removes downloaded models, transcripts, settings and the app's privacy-permission entries, then moves the app to the Trash.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成 Done") { dismiss() }
            }
        }
    }
}
