import SwiftUI
import FlowTranslateCore

/// Caption / language settings (US3): first-caption (ASR) language, second-caption
/// on/off and target language, plus presentation preferences. Bound to the live
/// `CaptionSettings`, applied immediately and persisted.
struct SettingsView: View {
    @Binding var settings: CaptionSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("第一字幕 First Caption (Recognition)") {
                Picker("辨識語言 Language", selection: $settings.firstLanguage) {
                    Text("自動偵測 / 混合語言 Auto").tag("auto")
                    ForEach(SupportedASRLanguages.all) { locale in
                        Text("\(locale.displayName) (\(locale.code))").tag(locale.code)
                    }
                }
                Picker("延遲 Latency tier", selection: $settings.asrTier) {
                    Text("最低延遲 Lowest (560ms)").tag("560ms")
                    Text("平衡準確 Balanced (1120ms)").tag("1120ms")
                }
            }

            Section("第二字幕 Second Caption (Translation)") {
                Toggle("啟用第二字幕 Enable", isOn: $settings.secondCaptionEnabled)
                Picker("目標語言 Target", selection: $settings.secondLanguage) {
                    ForEach(SecondCaptionLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .disabled(!settings.secondCaptionEnabled)
            }

            Section("呈現 Presentation") {
                HStack {
                    Text("字級 Font size")
                    Slider(value: $settings.fontSize, in: 12...22, step: 1)
                    Text("\(Int(settings.fontSize))")
                }
                Toggle("點透 Click-through overlay", isOn: $settings.clickThrough)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成 Done") { dismiss() }
            }
        }
    }
}
