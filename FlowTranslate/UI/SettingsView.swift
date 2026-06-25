import SwiftUI
import FlowTranslateCore

/// Caption / language settings (US3) + overlay presentation (redesign §4). Bound to
/// the live `CaptionSettings`, applied immediately and persisted. New overlay rows
/// (primary line, visible lines, interim style, opacity) are marked 「新」.
struct SettingsView: View {
    @Binding var settings: CaptionSettings
    @Environment(\.dismiss) private var dismiss

    /// Segmented "visible lines" (1/2/3) maps to `historyLineCount` (0/1/2 = now + N).
    private var visibleLines: Binding<Int> {
        Binding(get: { settings.historyLineCount + 1 },
                set: { settings.historyLineCount = max(0, min(2, $0 - 1)) })
    }

    var body: some View {
        Form {
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
            }

            Section("懸浮字幕 Overlay") {
                Picker(selection: $settings.primaryLineOnTop) {
                    Text("Original").tag(PrimaryLine.original)
                    Text("Translation").tag(PrimaryLine.translation)
                } label: { newRow("哪個語言在上面 Primary line") }
                .pickerStyle(.segmented)

                Picker(selection: visibleLines) {
                    Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                } label: { newRow("同時顯示句數 Visible lines") }
                .pickerStyle(.segmented)

                Picker(selection: $settings.interimStyle) {
                    Text("Dim + caret").tag(InterimStyle.dimmedWithCaret)
                    Text("Hidden").tag(InterimStyle.hidden)
                } label: { newRow("辨識中的文字 Interim text") }
                .pickerStyle(.segmented)

                HStack {
                    Text("字級 Font size")
                    Slider(value: $settings.overlayFontSize,
                           in: CaptionTheme.Metric.fontMin...CaptionTheme.Metric.fontMax, step: 1)
                    Text("\(Int(settings.overlayFontSize))pt").monospacedDigit().foregroundStyle(.secondary)
                }

                HStack {
                    newRow("背景透明度 Opacity")
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
            }

            Section {
                Label {
                    Text("完全在裝置上運作。聲音與文字不會離開你的 Mac，僅模型首次下載需要網路。")
                        .font(.caption).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(CaptionTheme.Palette.privacy)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成 Done") { dismiss() }
            }
        }
    }

    /// A row title with a small green 「新」 badge for redesign-introduced options.
    private func newRow(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("新").font(.system(size: 9.5, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(CaptionTheme.Palette.mic.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(CaptionTheme.Palette.mic)
        }
    }
}
