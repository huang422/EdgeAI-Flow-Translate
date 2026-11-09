import SwiftUI
import AppKit
import FlowTranslateCore
import os

// MARK: - Overlay view model

/// Listening state mirrored from the app's `ASRState` so the idle status pill can
/// reflect reality (listening / loading / warming / not listening) instead of
/// always claiming "Listening" even when stopped or still loading the model.
enum OverlayListenState { case idle, loading, warming, listening, failed }

/// Observable content + presentation state for the floating caption overlay.
/// Content lives in `CaptionBandState` (pure, unit-tested core logic): a current
/// utterance **slot** that morphs in place from interim to finalized (same view
/// identity → no jump), plus rolled-up history lines.
///
/// The band is pinned by its bottom edge. Bilingual paragraphs retain their view
/// identities as they roll up, and their full height determines the top edge.
@MainActor
final class OverlayModel: ObservableObject {
    // Content: the caption-band state machine (see FlowTranslateCore).
    @Published private(set) var band = CaptionBandState()

    /// Mirrors the app's ASR state so the idle pill reflects whether we are really
    /// listening, warming (model loading), or stopped — never a stale "Listening".
    @Published var listenState: OverlayListenState = .idle

    // Interaction state
    @Published var showControls = false

    // Presentation (mirrored from CaptionSettings)
    @Published var fontSize: Double = 16
    @Published var opacity: Double = 0.66
    @Published var showSecondLine = true
    @Published var primaryLineOnTop: PrimaryLine = .original
    @Published var historyLineCount: Int = 1 {
        didSet { band.historyLimit = historyLineCount }
    }
    @Published var interimStyle: InterimStyle = .markedWithCaret
    /// Mirrors the diarization setting: when on, every line reserves the fixed
    /// speaker-name slot so the label arriving at finalize can't shift the text.
    @Published var showSpeakerSlot = false
    @Published var reduceMotion = false

    // Set from the screen and bottom anchor by the panel controller.
    @Published var textWidth = CaptionTheme.Metric.overlayMaxWidth
    @Published var availableCaptionHeight = CGFloat.greatestFiniteMagnitude

    var isPinned: Bool { band.isPinned }

    // MARK: - Band events (called by CaptureViewModel)

    /// Live partial for the displayed utterance (same id all utterance long).
    func applyInterim(utteranceId: UUID, source: AudioSourceType,
                      english: String, chinese: String?, expectsTranslation: Bool) {
        guard interimStyle == .markedWithCaret else { return }
        band.interim(utteranceId: utteranceId, source: source, english: english,
                     chinese: chinese, expectsTranslation: expectsTranslation,
                     fitsOriginal: originalWidthCheck(expectsTranslation: expectsTranslation))
    }

    /// Finalized utterance, cleaned + split; the last sentence morphs the slot.
    func applyCommit(utteranceId: UUID?, source: AudioSourceType,
                     sentences: [(key: UUID, english: String)], expectsTranslation: Bool,
                     speakerLabel: String? = nil,
                     provisional: [UUID: String] = [:]) {
        band.commit(utteranceId: utteranceId, source: source,
                    sentences: sentences, expectsTranslation: expectsTranslation,
                    speakerLabel: speakerLabel, provisional: provisional,
                    fitsOriginal: originalWidthCheck(expectsTranslation: expectsTranslation,
                                                     hasSpeaker: speakerLabel != nil))
    }

    private func originalWidthCheck(expectsTranslation: Bool, hasSpeaker: Bool = false) -> (String) -> Bool {
        let secondary = showSecondLine && expectsTranslation && primaryLineOnTop != .original
        let font = NSFont.systemFont(ofSize: fontSize * (secondary ? 0.82 : 1), weight: .semibold)
        let speakerWidth = showSpeakerSlot || hasSpeaker
            ? CaptionTheme.speakerSlotWidth + CaptionTheme.Metric.gutterSpacing : 0
        let width = max(12, textWidth - speakerWidth - CaptionTheme.Metric.gutterSpacing
                        - CaptionTheme.Metric.dotSize - 8)
        return { ($0 as NSString).size(withAttributes: [.font: font]).width <= width }
    }

    /// Accurate translation for a finalized sentence.
    func applyTranslation(key: UUID, text: String) {
        band.translation(key: key, text: text)
    }

    /// Prefix-stable live translation for the in-progress slot.
    func applyInterimTranslation(utteranceId: UUID, text: String) {
        band.interimTranslation(utteranceId: utteranceId, text: text)
    }

    /// Drop an in-progress slot whose utterance produced nothing usable.
    func applyDiscard(utteranceId: UUID) {
        band.discard(utteranceId: utteranceId)
    }

    func addPresentedSpeakerGroup(
        utteranceId: UUID, key: UUID, original: String, speaker: String?, isLast: Bool
    ) {
        band.addPresentedSpeakerGroup(utteranceId: utteranceId, key: key,
                                      original: original, speaker: speaker, isLast: isLast)
    }

    func previewOriginalFinal(utteranceId: UUID, text: String, expectsTranslation: Bool) {
        band.previewOriginalFinal(utteranceId: utteranceId, text: text,
                                  fitsOriginal: originalWidthCheck(expectsTranslation: expectsTranslation))
    }

    func togglePin() { band.togglePin() }

    func clear() {
        band.clear()
    }

    /// Latest finalized line (used by the copy action).
    var latest: BandLine? { band.latestFinal }
}

/// Callbacks the SwiftUI overlay invokes back into the `OverlayController`.
struct OverlayActions {
    var onSize: (CGSize) -> Void = { _ in }
    var onOverflow: (Bool) -> Void = { _ in }
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    var onReset: () -> Void = {}
}

// MARK: - Shared visual pieces

/// `NSVisualEffectView` HUD blur behind the scrim (≈ blur 26 / saturation 150%).
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private enum OverlayChrome {
    static let side: CGFloat = 24
    static let top: CGFloat = 8
    static let shadowBottom: CGFloat = 30
    static let controlBottom: CGFloat = 40
    static let captionTop: CGFloat = 14
    static let captionBottom: CGFloat = 6
    static let panelWidthInset = 2 * (side + CaptionTheme.Metric.overlayScrimHPadding)
    static let panelHeightInset = top + controlBottom + captionTop + captionBottom
}

private extension View {
    /// The dark blurred caption backdrop (scrim): tint + rounded corners + inset
    /// hairline + drop shadow. Amber outline when pinned.
    func scrim(opacity: Double, pinned: Bool = false,
               bottomInset: CGFloat = OverlayChrome.shadowBottom) -> some View {
        let corner = CaptionTheme.Metric.scrimCorner
        let border = pinned ? CaptionTheme.Palette.pin.opacity(0.45) : Color.white.opacity(0.09)
        return self.background(
            ZStack {
                VisualEffectBlur()
                CaptionTheme.Palette.overlayScrim.opacity(opacity)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .inset(by: 0.5)
                .stroke(border, lineWidth: pinned ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 11, x: 2, y: 4)
        // Room below for the shadow, which falls 4 pt down with an 11 pt blur.
        // The control strip is above the scrim again, so there is nothing under
        // it to catch the shadow and the panel's own edge would clip it.
        .padding(.horizontal, OverlayChrome.side)
        .padding(.top, OverlayChrome.top)
        .padding(.bottom, bottomInset)
    }
}

/// A source-colour dot marking which input produced a finalized line.
struct SourceDot: View {
    let color: Color
    var size: CGFloat = CaptionTheme.Metric.dotSize
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// A pulsing "breathing" ring around a dot (listening / recording cues).
struct BreathingDot: View {
    let color: Color
    var animated: Bool = true
    var size: CGFloat = 7
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: size, height: size)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .scaleEffect(pulse ? 2.6 : 1)
                .opacity(pulse ? 0 : 0.9)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// A horizontal dotted underline used under the interim text.
private struct DottedUnderline: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return p
    }
}

// MARK: - Caption band line

/// One line of the caption band. The SAME view renders the line through its whole
/// life. Interim words may interpolate; finalized text does not crossfade when
/// its paragraph rolls up.
///
/// **The text itself never changes appearance.** One colour, one weight, full
/// strength, whether the line is in progress, newest or old — so a sentence
/// ending doesn't flash anything. Only the ornaments switch: a breathing dot,
/// blinking caret and dotted underline while recognizing, a static source dot
/// once finalized.
private struct BandLineView: View {
    let line: BandLine
    let fontSize: Double
    let primaryOnTop: PrimaryLine
    let showSecond: Bool
    /// Whether to reserve the fixed speaker-name slot (diarization on).
    let showSpeakerSlot: Bool
    let reduceMotion: Bool

    /// Non-empty translation text, if any.
    private var translation: String? {
        guard let t = line.chinese?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
    }

    /// Whether the reserved second row is rendered at all.
    private var showSecondRow: Bool { showSecond && line.expectsTranslation }

    /// Second-row display text: translation, "⋯" while a finalized line waits
    /// for its translation, or a space placeholder holding the reserved height.
    private var secondRowText: String {
        translation ?? (line.isFinal ? "⋯" : " ")
    }

    /// Keep the row ORDER fixed by the primary-line setting (even while the
    /// translation is still pending) so the finalize morph never swaps rows.
    private var englishOnTop: Bool { !showSecondRow || primaryOnTop == .original }

    /// Reserve the speaker column when diarization is on — OR whenever a label
    /// actually exists, so a label can never be dropped just because the mirrored
    /// setting is stale.
    private var reservesSpeakerSlot: Bool { showSpeakerSlot || line.speakerLabel != nil }

    /// Dot and speaker beside a column holding both caption rows.
    ///
    /// A column rather than a label inside the first row: wrapped to two lines,
    /// its second line hangs below the first baseline and makes the whole row
    /// taller, which opens a blank gap between the English and the Chinese —
    /// exactly the vertical jump this band is built to avoid. As a column it
    /// spans both rows instead: two
    /// lines of 10 pt label are shorter than two caption rows, so it stops
    /// driving the height at all.
    ///
    /// It also deletes `secondRowIndent`. The translation lines up with the text
    /// above it because they are in the same column now, rather than because a
    /// padding was computed to match the gutter — which had to be kept in step by
    /// hand, and had already been wrong once.
    /// One caption unit, as tall as its own text — the two rows adjacent, with
    /// nothing reserved between them.
    ///
    /// The original and its translation wrap together at the configured font
    /// sizes. The viewport clips old paragraphs at its top, never a text tail
    /// with a separate one-row limit.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CaptionTheme.Metric.gutterSpacing) {
            dot
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
            speakerLabel
            VStack(alignment: .leading, spacing: CaptionTheme.Metric.rowGap) {
                Group {
                    if englishOnTop {
                        englishRow(font: CaptionTheme.primaryFont(fontSize), color: topColor)
                    } else {
                        Text(secondRowText)
                            .font(CaptionTheme.primaryFont(fontSize).weight(.semibold))
                            .contentTransition(line.isFinal || reduceMotion ? .identity : .interpolate)
                            .foregroundStyle(translation == nil ? CaptionTheme.Palette.inkTertiary : topColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if showSecondRow {
                    Group {
                        if englishOnTop {
                            Text(secondRowText)
                                .font(CaptionTheme.translationFont(fontSize))
                                .contentTransition(line.isFinal || reduceMotion ? .identity : .interpolate)
                                .foregroundStyle(bottomColor)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            englishRow(font: CaptionTheme.translationFont(fontSize), color: bottomEnglishColor)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reserve the label column before diarization returns. Late speaker
    /// names can then appear without changing the original text's width.
    @ViewBuilder
    private var speakerLabel: some View {
        if reservesSpeakerSlot {
            CaptionSpeakerLabel(name: line.speakerLabel ?? (line.source == .system ? "系統音訊" : "麥克風"),
                                reservesSpace: true)
        }
    }

    /// The recognition-text row: caret + dotted underline live HERE (wherever the
    /// English sits), never on a possibly-empty translation row.
    ///
    private func englishRow(font: Font, color: Color) -> some View {
        let rows = line.originalRows.rows.isEmpty ? [line.english] : line.originalRows.rows
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let open = line.isOpen && index == rows.count - 1
                ZStack(alignment: .topLeading) {
                    if reservesSpeakerSlot {
                        // Reserve the same two-line height before a late label
                        // arrives. The name sits in the existing column.
                        CaptionSpeakerLabel(name: index > 0 ? line.originalSpeakerLabels[index] ?? "" : "",
                                            reservesSpace: true)
                            .offset(x: -CaptionTheme.speakerSlotWidth - CaptionTheme.Metric.gutterSpacing)
                            .frame(width: 0, alignment: .leading)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(rows[index])
                            .font(font.weight(.semibold))
                            .contentTransition(.identity)
                            .foregroundStyle(color)
                            .fixedSize(horizontal: false, vertical: true)
                            .overlay(alignment: .bottom) {
                                if open {
                                    DottedUnderline()
                                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2.5]))
                                        .foregroundStyle(Color(hex: 0xF5F5F7).opacity(0.3))
                                        .frame(height: 1.5)
                                        .offset(y: 3)
                                }
                            }
                        if open { BlinkingCaret(height: fontSize * 0.95, animated: !reduceMotion) }
                    }
                }
                .transition(reduceMotion ? .identity : .move(edge: .bottom))
            }
        }
    }

    // MARK: Styling

    @ViewBuilder
    private var dot: some View {
        if !line.isOpen {
            // No glow-on-latest: that marked "newest", which the band's own
            // bottom-up order already says, and it made every sentence boundary
            // animate something. The dot's only job is source colour.
            SourceDot(color: CaptionTheme.Palette.sourceDot(line.source))
        } else {
            BreathingDot(color: CaptionTheme.Palette.stopRec, animated: !reduceMotion,
                         size: CaptionTheme.Metric.dotSize)
                .frame(width: CaptionTheme.Metric.dotSize, height: CaptionTheme.Metric.dotSize)
        }
    }

    // Recognition and translation each have exactly ONE colour, whatever the
    // line's state. Carrying "in progress" in brightness makes the live line —
    // the one being read right now — dimmer than the sentence that just ended,
    // and flashes two lines in opposite directions on every finalize. State is
    // the dot, caret and underline's job.

    private var topColor: Color { CaptionTheme.Palette.inkPrimary }

    private var bottomColor: Color {
        // The ⋯ placeholder is not caption text — dimming it says "still coming",
        // and the real translation replaces it at full strength.
        translation == nil ? CaptionTheme.Palette.inkTertiary : CaptionTheme.Palette.inkTranslation
    }

    /// English shown on the bottom row (translation-on-top layout).
    private var bottomEnglishColor: Color { CaptionTheme.Palette.inkTranslation }
}

/// A 2pt vertical caret that blinks once per second (steps), or stays solid when
/// "reduce motion" is on.
private struct BlinkingCaret: View {
    let height: CGFloat
    let animated: Bool
    var body: some View {
        Group {
            if animated {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    caret.opacity(on ? 1 : 0)
                }
            } else {
                caret
            }
        }
    }
    private var caret: some View {
        Rectangle()
            .fill(Color(hex: 0x9AA8C2))
            .frame(width: 2, height: height)
    }
}

/// Amber "pinned / paused" banner with a +N pending count.
private struct PinnedBanner: View {
    let pending: Int
    var body: some View {
        HStack(spacing: 7) {
            Text("📌").font(.system(size: 11))
            Text(pending > 0 ? "已釘選 · 捲動暫停 +\(pending)" : "已釘選 · 捲動暫停，方便閱讀")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFFB340))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(CaptionTheme.Palette.pin.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(CaptionTheme.Palette.pin.opacity(0.3), lineWidth: 1))
    }
}

/// Minimal status pill shown when there's no caption yet — reflects the real
/// ASR state so it never claims "Listening" while loading or stopped (idle).
private struct ListeningPill: View {
    let state: OverlayListenState

    var body: some View {
        HStack(spacing: 9) {
            dot
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0xC9CDD4))
        }
        .padding(.horizontal, 15).padding(.vertical, 9)
        .scrim(opacity: 0.72)
    }

    @ViewBuilder
    private var dot: some View {
        switch state {
        case .listening:
            BreathingDot(color: CaptionTheme.Palette.mic, size: 7).frame(width: 7, height: 7)
        case .loading, .warming:
            BreathingDot(color: CaptionTheme.Palette.accentSystem, size: 7).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(.orange).frame(width: 7, height: 7)
        case .idle:
            Circle().fill(CaptionTheme.Palette.inkTertiary).frame(width: 7, height: 7)
        }
    }

    private var text: String {
        switch state {
        case .listening: return "聆聽中… Listening"
        case .loading:   return "準備模型… Preparing"
        case .warming:   return "模型載入中 Loading model"
        case .failed:    return "模型載入失敗 Model load failed"
        case .idle:      return "待命 Idle"
        }
    }
}

// MARK: - Hover control bar

private struct OverlayControlBar: View {
    @ObservedObject var model: OverlayModel
    let actions: OverlayActions

    var body: some View {
        HStack(spacing: 2) {
            dragHandle
            divider
            controlButton("↺", size: 14, color: Color(hex: 0xC9CDD4)) { actions.onReset() }
                .help("回復預設位置與外觀 Reset position and appearance")
        }
        .padding(4)
        .background(Color(hex: 0x26262B).opacity(0.96), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 11, x: 0, y: 8)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 20)
    }

    /// 2×3 dot drag handle that moves the whole panel.
    private var dragHandle: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2) {
                    Circle().fill(Color(hex: 0x8A8F99)).frame(width: 2.5, height: 2.5)
                    Circle().fill(Color(hex: 0x8A8F99)).frame(width: 2.5, height: 2.5)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { actions.onDrag($0.translation) }
                .onEnded { _ in actions.onDragEnd() }
        )
        .help("拖曳移動 Drag to move")
    }

    private func controlButton(_ label: String, size: CGFloat, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Root overlay view

private struct OverlayRootView: View {
    @ObservedObject var model: OverlayModel
    let actions: OverlayActions

    @State private var intrinsicCaptionHeight: CGFloat = 20
    @State private var liveHeight: LiveMeasurement?

    private struct LiveKey: Equatable {
        let id: UUID
        let width: CGFloat
        let fontSize: Double
        let secondLine: Bool
        let primary: PrimaryLine
        let speakerSlot: Bool
    }

    private struct LiveMeasurement: Equatable {
        let key: LiveKey?
        let height: CGFloat
    }

    private var liveKey: LiveKey? {
        guard let line = model.band.visibleSlot, !line.isFinal,
              model.interimStyle == .markedWithCaret
        else { return nil }
        return LiveKey(id: line.id, width: model.textWidth, fontSize: model.fontSize,
                       secondLine: model.showSecondLine, primary: model.primaryLineOnTop,
                       speakerSlot: model.showSpeakerSlot)
    }

    /// The corner the controls occupy, measured from the panel's bottom-right.
    /// Read by the controller too: the hit-test and the hover rectangle have to
    /// agree with the layout, and hand-copied numbers drift.
    ///
    /// Generous against the controls' own size — the scrim's shadow padding sits
    /// below them and a press just off a button should still land.
    static let controlCornerSize = CGSize(width: 120, height: 76)

    var body: some View {
        content
        .fixedSize()
        .animation(model.reduceMotion ? nil : .easeOut(duration: CaptionTheme.Metric.controlsDuration), value: model.showControls)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { actions.onSize($0) }
        // AppKit owns the panel frame. Align content to its lower edge while
        // the measured height and the window frame settle after a caption update.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Show the caption band whenever a meeting is running (warming counts — the
    /// band doubles as the "captions will appear here" affordance) or content
    /// remains on screen (e.g. pinned for reading after the meeting ended).
    private var showBand: Bool {
        model.listenState == .listening || model.listenState == .warming || model.listenState == .failed
            || model.band.hasContent
    }

    @ViewBuilder
    private var content: some View {
        if showBand {
            captionBand
        } else {
            // Lay the idle pill out at the full caption width (scrim stays pill-sized,
            // centred) so the centre-anchored window keeps a constant width and never
            // shifts horizontally when content toggles idle ↔ caption.
            ListeningPill(state: model.listenState)
                .frame(width: model.textWidth + CaptionTheme.Metric.overlayScrimHPadding * 2, alignment: .center)
        }
    }

    private var captionBand: some View {
        let overflow = intrinsicCaptionHeight > model.availableCaptionHeight
        return Group {
            if overflow {
                ScrollView { captionStack }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: model.availableCaptionHeight)
            } else {
                captionStack
            }
        }
        .frame(width: model.textWidth)
        .onChange(of: overflow, initial: true) { _, current in actions.onOverflow(current) }
        .onChange(of: model.band.isPinned) { _, _ in actions.onOverflow(overflow) }
        .padding(.horizontal, CaptionTheme.Metric.overlayScrimHPadding)
        .padding(.top, OverlayChrome.captionTop)
        .padding(.bottom, OverlayChrome.captionBottom)
        .scrim(opacity: model.opacity, pinned: model.band.isPinned, bottomInset: OverlayChrome.controlBottom)
        // Reserve the shadow gutter for controls so they never cover text.
        .overlay(alignment: .bottomTrailing) {
            OverlayControlBar(model: model, actions: actions)
                .opacity(model.showControls ? 1 : 0)
                .allowsHitTesting(model.showControls)
                .padding(.trailing, OverlayChrome.side)
                .padding(.bottom, 3)
        }
        .onDisappear { actions.onOverflow(false) }
    }

    private var captionStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.band.isPinned {
                PinnedBanner(pending: model.band.pendingWhilePinned)
            }
            bandContent
        }
        .frame(width: model.textWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
            intrinsicCaptionHeight = height
        }
    }

    private var displayedLines: [BandLine] {
        model.band.visibleLines(showInterim: model.interimStyle == .markedWithCaret)
    }

    private var bandContent: some View {
        let key = liveKey
        return VStack(alignment: .leading, spacing: CaptionTheme.Metric.unitSpacing) {
            ForEach(displayedLines) { line in
                let measuredKey = key?.id == line.id ? key : nil
                bandLineView(line)
                    .onGeometryChange(for: LiveMeasurement.self) {
                        LiveMeasurement(key: measuredKey, height: ceil($0.size.height))
                    } action: { measurement in
                        guard let active = measurement.key, active == liveKey else { return }
                        if liveHeight?.key != active || measurement.height > (liveHeight?.height ?? 0) {
                            liveHeight = measurement
                        }
                    }
                    .frame(minHeight: measuredKey != nil && measuredKey == liveHeight?.key
                           ? liveHeight?.height : nil, alignment: .bottomLeading)
                    .transition(model.reduceMotion ? .identity : .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
            if displayedLines.isEmpty { bandStatusRow }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(model.reduceMotion ? nil : .easeOut(duration: CaptionTheme.Metric.evictDuration),
                   value: displayedLines.map(\.id))
        .animation(model.reduceMotion ? nil : .easeOut(duration: CaptionTheme.Metric.evictDuration),
                   value: displayedLines.map { $0.originalRows.rows.count })
    }

    private func bandLineView(_ line: BandLine) -> some View {
        BandLineView(
            line: line,
            fontSize: model.fontSize,
            primaryOnTop: model.primaryLineOnTop,
            showSecond: model.showSecondLine,
            showSpeakerSlot: model.showSpeakerSlot,
            reduceMotion: model.reduceMotion
        )
    }

    /// Small status row inside the (otherwise empty) band, so a fresh meeting
    /// shows where captions will appear and whether the model is still loading.
    private var bandStatusRow: some View {
        HStack(spacing: 8) {
            switch model.listenState {
            case .warming:
                BreathingDot(color: CaptionTheme.Palette.accentSystem, animated: !model.reduceMotion, size: 6)
                    .frame(width: 6, height: 6)
                Text("模型載入中…請等候辨識就緒再說話")
            case .failed:
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text("模型載入失敗 · 請回主視窗結束後重試")
            case .listening:
                BreathingDot(color: CaptionTheme.Palette.mic, animated: !model.reduceMotion, size: 6)
                    .frame(width: 6, height: 6)
                Text("聆聽中… Listening")
            case .loading:
                BreathingDot(color: CaptionTheme.Palette.accentSystem, animated: !model.reduceMotion, size: 6)
                    .frame(width: 6, height: 6)
                Text("準備模型… Preparing")
            case .idle:
                Circle().fill(CaptionTheme.Palette.inkTertiary).frame(width: 6, height: 6)
                Text("待命 Idle")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color(hex: 0xC9CDD4).opacity(0.85))
    }
}

// MARK: - Passthrough hosting view

/// Hosting view that only "grabs" mouse clicks in the control-bar band (when
/// controls are showing); everything else returns nil so clicks fall through to the
/// app below. Pure passthrough is still handled by `ignoresMouseEvents` when not
/// hovering.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var controlsVisible: () -> Bool = { false }
    var canScrollCaptions: () -> Bool = { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if canScrollCaptions() { return super.hitTest(point) }
        guard controlsVisible() else { return nil }
        // Bottom-left origin, so the controls' corner is low y and high x.
        let corner = OverlayRootView.controlCornerSize
        if point.y <= corner.height, point.x >= bounds.width - corner.width {
            return super.hitTest(point)
        }
        return nil
    }
}

// MARK: - Panel

/// A panel AppKit is not allowed to reposition.
///
/// **This is why the bottom edge moved, and only at three lines.** Every
/// `setFrame` goes through `constrainFrameRect(_:to:)`, whose job is to keep a
/// window's title bar reachable — and the way it does that is to **push the
/// window down** when its top would rise above the screen's visible area. The
/// overlay has no title bar and is anchored by its bottom edge, so that is
/// precisely the wrong correction: the anchor the user placed slides downward,
/// by exactly as much as the box grew.
///
/// It bites by height, which is why one and two captions were fine and three
/// were not — three is the first setting tall enough to reach the top of the
/// space above the anchor. Nothing in this file could have prevented it, because
/// the frame this class computes was already right; AppKit changed it afterwards.
///
/// Returning the rect unchanged is the documented way to opt out. The overlay
/// keeps itself on screen anyway: `applyContentSize` clamps the origin to the
/// visible frame's lower edge, which is the one direction that would otherwise
/// lose the newest caption.
private final class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Overlay controller (NSPanel manager)

/// Manages the floating-caption `NSPanel`: always on top (incl. full-screen apps),
/// click-through except over the hover control bar, draggable with a persisted
/// position, and auto-sized to its caption content.
@MainActor
final class OverlayController {

    private static let log = Logger(subsystem: "dev.flowtranslate.app", category: "overlay")

    let model = OverlayModel()

    /// Caller hooks: persist a moved position / a font step / a reset-to-defaults.
    var onPositionChanged: ((CGPoint) -> Void)?
    var onReset: (() -> Void)?

    private var panel: NSPanel?
    private var hostingView: PassthroughHostingView<OverlayRootView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var clickThroughEnabled = true
    private var isHovering = false
    private var captionsOverflow = false
    private var defaultAnchor: CGPoint?
    /// Where the overlay is pinned: `x` is its horizontal centre, `y` is its
    /// **bottom edge**. `nil` until the user drags it.
    ///
    /// The bottom, not the top, and that is the whole geometry of this window.
    /// The height changes whenever the text reflows, so anchoring the top moves
    /// the bottom — and the bottom is where the newest caption is, the line being
    /// read.
    ///
    /// It is also what is **persisted**. A stored top-centre point cannot be
    /// turned back into a bottom edge without knowing the height it was saved at,
    /// so every call before the first measured layout would re-derive
    /// `bottom = top − height` and move the bottom edge down by any growth.
    /// Storing the edge that does not move removes the arithmetic entirely.
    private var pinnedBottom: CGPoint?
    /// The stored anchor as last seen from settings, so `applySettings` can tell a
    /// real change (the user dragged) from an unrelated settings write.
    private var lastAppliedStoredAnchor: CGPoint?
    private var dragMouseStart: CGPoint?
    private var dragOriginStart: CGPoint?
    private var lastContentSize: CGSize = .zero

    // MARK: Lifecycle

    func show() {
        if panel == nil { panel = makePanel() }
        // Apply the current click-through state to the (possibly new) panel.
        if clickThroughEnabled {
            panel?.ignoresMouseEvents = !isHovering
            model.showControls = isHovering
        } else {
            panel?.ignoresMouseEvents = false
            model.showControls = true
        }
        applyContentSize(lastContentSize == .zero ? CGSize(width: CaptionTheme.Metric.overlayTotalWidth, height: 120) : lastContentSize)
        installMonitors()
        panel?.orderFrontRegardless()
    }

    func hide() {
        removeMonitors()
        setHovering(false)
        panel?.orderOut(nil)
    }

    // MARK: Settings

    /// Mirror the overlay-related settings into the model + panel.
    func applySettings(_ s: CaptionSettings) {
        model.fontSize = s.overlayFontSize
        model.opacity = s.overlayOpacity
        model.showSecondLine = s.secondCaptionEnabled
        model.primaryLineOnTop = s.primaryLineOnTop
        model.historyLineCount = s.historyLineCount
        model.interimStyle = s.interimStyle
        model.showSpeakerSlot = s.diarizationEnabled
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        clickThroughEnabled = s.clickThrough
        // Keep the active drag position across unrelated settings changes.
        if s.overlayBottomAnchor != lastAppliedStoredAnchor {
            lastAppliedStoredAnchor = s.overlayBottomAnchor
            // Adopted verbatim: the stored point IS the bottom edge, so there is
            // nothing to derive and nothing that has to wait for a measurement.
            pinnedBottom = s.overlayBottomAnchor
        }
        if !clickThroughEnabled {
            // Always interactive: never swallow the app below, controls available.
            panel?.ignoresMouseEvents = false
            model.showControls = true
        } else if !isHovering {
            panel?.ignoresMouseEvents = true
            model.showControls = false
        }
        applyContentSize(lastContentSize)
    }

    func togglePin() { model.togglePin() }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let root = OverlayRootView(model: model, actions: makeActions())
        let hosting = PassthroughHostingView(rootView: root)
        hosting.sizingOptions = []   // only applyContentSize may resize the panel
        hosting.controlsVisible = { [weak self] in self?.model.showControls ?? false }
        hosting.canScrollCaptions = { [weak self] in self?.canScrollCaptions ?? false }
        self.hostingView = hosting

        let panel = UnconstrainedPanel(
            contentRect: NSRect(x: 0, y: 0, width: CaptionTheme.Metric.overlayTotalWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver                 // above full-screen meetings / video
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                    // the scrim draws its own shadow
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true       // so the local monitor sees hover-exit
        panel.ignoresMouseEvents = true            // default: full click-through
        panel.contentView = hosting
        return panel
    }

    private func makeActions() -> OverlayActions {
        OverlayActions(
            onSize: { [weak self] in self?.applyContentSize($0) },
            onOverflow: { [weak self] overflowing in
                self?.captionsOverflow = overflowing
                self?.updateHover()
            },
            onDrag: { [weak self] in self?.dragChanged($0) },
            onDragEnd: { [weak self] in self?.dragEnded() },
            onReset: { [weak self] in self?.onReset?() }
        )
    }

    /// The anchor chooses the display. Growing the frame cannot choose another
    /// display and unexpectedly move the anchor during a caption update.
    private func applyContentSize(_ size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        lastContentSize = size
        if defaultAnchor == nil, let screen = panel.screen ?? NSScreen.main {
            defaultAnchor = defaultBottom(in: screen.visibleFrame)
        }
        guard let anchor = pinnedBottom ?? defaultAnchor,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        else { return }
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let panelWidth = min(CaptionTheme.Metric.overlayMaxWidth + OverlayChrome.panelWidthInset,
                             available.width)
        // If a saved position is off-screen, leave at least a small viewport.
        let minRoom = min(160, available.height)
        let bottom = min(max(anchor.y, available.minY), available.maxY - minRoom)
        let textWidth = max(1, panelWidth - OverlayChrome.panelWidthInset)
        let heightLimit = max(1, available.maxY - bottom - OverlayChrome.panelHeightInset)
        if model.textWidth != textWidth { model.textWidth = textWidth }
        if model.availableCaptionHeight != heightLimit { model.availableCaptionHeight = heightLimit }

        let height = min(ceil(size.height), available.maxY - bottom)
        let x = min(max(anchor.x - panelWidth / 2, available.minX), available.maxX - panelWidth)
        let frame = NSRect(x: x, y: bottom, width: panelWidth, height: height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// Default placement: horizontally centred, sitting `overlayBottomFraction`
    /// up from the bottom of the visible frame. Independent of the window's
    /// height, which is what made the un-dragged case already correct.
    private func defaultBottom(in vf: NSRect) -> CGPoint {
        CGPoint(x: vf.midX, y: vf.minY + vf.height * CaptionTheme.Metric.overlayBottomFraction)
    }

    // MARK: Drag

    /// Move the panel using the **absolute** mouse position (screen coords), which —
    /// unlike the SwiftUI gesture translation — is immune to the window moving out
    /// from under the gesture's own coordinate space mid-drag.
    private func dragChanged(_ translation: CGSize) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragMouseStart == nil {
            dragMouseStart = mouse
            dragOriginStart = panel.frame.origin
        }
        guard let ms = dragMouseStart, let os = dragOriginStart else { return }
        let newOrigin = CGPoint(x: os.x + (mouse.x - ms.x), y: os.y + (mouse.y - ms.y))
        // Use the same screen bounds for dragging and content changes.
        let size = panel.frame.size
        pinnedBottom = CGPoint(x: newOrigin.x + size.width / 2, y: newOrigin.y)
        applyContentSize(lastContentSize)
    }

    private func dragEnded() {
        guard let panel else { return }
        dragMouseStart = nil
        dragOriginStart = nil
        let f = panel.frame
        lastContentSize = f.size
        // Persisted as the bottom-centre point — the same value `pinnedBottom`
        // holds, so a restore is an assignment rather than a reconstruction.
        let anchor = CGPoint(x: f.midX, y: f.minY)
        pinnedBottom = anchor
        // Recorded as "already applied" so the round trip through settings does
        // not read it back as a fresh change.
        lastAppliedStoredAnchor = anchor
        onPositionChanged?(anchor)
    }


    // MARK: Hover monitors

    private func installMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateHover()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.updateHover(); return e
        }
    }

    private func removeMonitors() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
    }

    private func updateHover() {
        guard clickThroughEnabled, let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let overPanel = frame.insetBy(dx: -8, dy: -8).contains(mouse)
        // The controls live in the panel's bottom-right corner; ONLY that region
        // captures clicks. Derived from the layout constant rather than restated,
        // because this rectangle and `PassthroughHostingView`'s corner describe one
        // area, and a disagreement between them is a control that lights up but
        // cannot be clicked.
        let corner = OverlayRootView.controlCornerSize
        let band = NSRect(x: frame.maxX - corner.width - 8, y: frame.minY - 8,
                          width: corner.width + 16, height: corner.height + 16)
        let overBand = overPanel && band.contains(mouse)
        if overPanel != isHovering {
            isHovering = overPanel
            model.showControls = overPanel
        }
        panel.ignoresMouseEvents = !(overBand || (overPanel && canScrollCaptions))
    }

    // Pinning deliberately enters reading mode. Live subtitles remain
    // click-through even when their content is taller than the screen.
    private var canScrollCaptions: Bool {
        captionsOverflow && (!clickThroughEnabled || model.band.isPinned)
    }

    private func setHovering(_ inside: Bool) {
        isHovering = inside
        if !inside {
            model.showControls = false
            if clickThroughEnabled { panel?.ignoresMouseEvents = true }
        }
    }
}
