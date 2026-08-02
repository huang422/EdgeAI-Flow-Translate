import SwiftUI
import AppKit
import FlowTranslateCore

// MARK: - Overlay view model

/// Listening state mirrored from the app's `ASRState` so the idle status pill can
/// reflect reality (listening / loading / warming / not listening) instead of
/// always claiming "Listening" even when stopped or still loading the model.
enum OverlayListenState { case idle, loading, warming, listening }

/// Observable content + presentation state for the floating caption overlay.
/// Content lives in `CaptionBandState` (pure, unit-tested core logic): a current
/// utterance **slot** that morphs in place from interim to finalized (same view
/// identity → no jump), plus rolled-up history lines. The band geometry is fixed
/// from settings, so the panel frame never changes while captions stream.
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

    var isPinned: Bool { band.isPinned }

    // MARK: - Band events (called by CaptureViewModel)

    /// Live partial for the displayed utterance (same id all utterance long).
    func applyInterim(utteranceId: UUID, source: AudioSourceType,
                      english: String, chinese: String?, expectsTranslation: Bool) {
        band.interim(utteranceId: utteranceId, source: source, english: english,
                     chinese: chinese, expectsTranslation: expectsTranslation)
    }

    /// Finalized utterance, cleaned + split; the last sentence morphs the slot.
    func applyCommit(utteranceId: UUID?, source: AudioSourceType,
                     sentences: [(key: UUID, english: String)], expectsTranslation: Bool,
                     speakerLabel: String? = nil) {
        band.commit(utteranceId: utteranceId, source: source,
                    sentences: sentences, expectsTranslation: expectsTranslation,
                    speakerLabel: speakerLabel)
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

    func togglePin() { band.togglePin() }

    func clear() { band.clear() }

    /// Latest finalized line (used by the copy action).
    var latest: BandLine? { band.latestFinal }
}

/// Callbacks the SwiftUI overlay invokes back into the `OverlayController`.
struct OverlayActions {
    var onSize: (CGSize) -> Void = { _ in }
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    var onPin: () -> Void = {}
    var onCopy: () -> Void = {}
    var onFont: (Int) -> Void = { _ in }
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

private extension View {
    /// The dark blurred caption backdrop (scrim): tint + rounded corners + inset
    /// hairline + drop shadow. Amber outline when pinned.
    func scrim(opacity: Double, pinned: Bool = false) -> some View {
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
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 30)
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
/// life, and the text morphs in place via `contentTransition(.interpolate)` (new
/// words fade in; cleanup edits crossfade).
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

    /// Where the second row must start so it lines up with the text above it —
    /// derived from the gutter that is actually rendered, not a magic number.
    /// This was hardcoded at 14 (dot + one gap), which silently misaligned the
    /// translation the moment the speaker slot widened the gutter.
    private var secondRowIndent: CGFloat {
        var x = CaptionTheme.Metric.dotSize + CaptionTheme.Metric.gutterSpacing
        if reservesSpeakerSlot {
            x += speakerSlotWidth + CaptionTheme.Metric.gutterSpacing
        }
        return x
    }

    private var speakerSlotWidth: CGFloat {
        CaptionTheme.speakerSlotWidth(labelSize: CaptionTheme.speakerLabelSize(fontSize))
    }

    /// Reserve the speaker column when diarization is on — OR whenever a label
    /// actually exists, so a label can never be dropped just because the mirrored
    /// setting is stale.
    private var reservesSpeakerSlot: Bool { showSpeakerSlot || line.speakerLabel != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: CaptionTheme.Metric.rowGap) {
            HStack(alignment: .firstTextBaseline, spacing: CaptionTheme.Metric.gutterSpacing) {
                dot
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
                speakerLabel
                if englishOnTop {
                    englishRow(font: CaptionTheme.primaryFont(fontSize), color: topColor)
                } else {
                    Text(secondRowText)
                        .font(CaptionTheme.primaryFont(fontSize).weight(.semibold))
                        .contentTransition(reduceMotion ? .identity : .interpolate)
                        .foregroundStyle(translation == nil ? CaptionTheme.Palette.inkTertiary : topColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showSecondRow {
                Group {
                    if englishOnTop {
                        Text(secondRowText)
                            .font(CaptionTheme.translationFont(fontSize))
                            .contentTransition(reduceMotion ? .identity : .interpolate)
                            .foregroundStyle(bottomColor)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        englishRow(font: CaptionTheme.translationFont(fontSize),
                                   color: bottomEnglishColor)
                    }
                }
                .padding(.leading, secondRowIndent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Speaker name in a FIXED-width slot, so the text's left edge never moves.
    /// The label only arrives at finalize — diarization runs on the completed
    /// utterance — so letting it push the sentence right would shift the text
    /// AND re-wrap it at the exact moment the speaker stopped talking. The slot
    /// exists only while diarization is on; otherwise the layout is unchanged.
    @ViewBuilder
    private var speakerLabel: some View {
        if reservesSpeakerSlot {
            Text(line.speakerLabel ?? "")
                .font(.system(size: CaptionTheme.speakerLabelSize(fontSize), weight: .bold))
                // `inkSecondary`, not `inkTertiary`: the speaker is a cue you
                // actually read, and the weakest ink is near-invisible on the
                // scrim at label size.
                .foregroundStyle(CaptionTheme.Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: speakerSlotWidth, alignment: .leading)
        }
    }

    /// The recognition-text row: caret + dotted underline live HERE (wherever the
    /// English sits), never on a possibly-empty translation row.
    ///
    /// The text wraps to as many lines as it needs — nothing is ever truncated.
    /// The band's viewport is what's fixed; text beyond it scrolls out of view
    /// (bottom-anchored, so the newest words stay put) and stays reachable.
    private func englishRow(font: Font, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(line.english)
                // One weight for every state. Medium→semibold on finalize was the
                // worst of the jumps: semibold is wider, so a sentence could
                // re-wrap the moment it ended and shove the whole band upward.
                .font(font.weight(.semibold))
                .contentTransition(reduceMotion ? .identity : .interpolate)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottom) {
                    if !line.isFinal {
                        DottedUnderline()
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2.5]))
                            .foregroundStyle(Color(hex: 0xF5F5F7).opacity(0.3))
                            .frame(height: 1.5)
                            .offset(y: 3)
                    }
                }
            if !line.isFinal {
                BlinkingCaret(height: fontSize * 0.95, animated: !reduceMotion)
            }
        }
    }

    // MARK: Styling

    @ViewBuilder
    private var dot: some View {
        if line.isFinal {
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
    // line's state. Brightness used to carry "in progress" and "newest", which
    // meant the live line — the one being read right now — was dimmer than the
    // sentence that had just ended, and every finalize flashed two lines in
    // opposite directions. State is the dot, caret and underline's job.

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
        case .idle:
            Circle().fill(CaptionTheme.Palette.inkTertiary).frame(width: 7, height: 7)
        }
    }

    private var text: String {
        switch state {
        case .listening: return "聆聽中… Listening"
        case .loading:   return "準備模型… Preparing"
        case .warming:   return "模型載入中…可先說話 Loading model"
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
            controlButton("📌", size: 13, color: model.isPinned ? CaptionTheme.Palette.pin : Color(hex: 0xC9CDD4)) {
                actions.onPin()
            }
            .help("釘選 / 暫停捲動 ⌃⌥P")
            controlButton("⧉", size: 12, color: Color(hex: 0xC9CDD4)) { actions.onCopy() }
                .help("複製這句 Copy")
            divider
            controlButton("A−", size: 14, color: Color(hex: 0xC9CDD4)) { actions.onFont(-1) }
                .help("縮小字級 ⌃⌥-")
            controlButton("A+", size: 16, color: Color(hex: 0xC9CDD4)) { actions.onFont(1) }
                .help("放大字級 ⌃⌥=")
            divider
            controlButton("↺", size: 14, color: Color(hex: 0xC9CDD4)) { actions.onReset() }
                .help("回復所有懸浮字幕設定預設值 Reset all overlay settings")
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

private struct OverlaySizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Top-level SwiftUI content hosted inside the floating `NSPanel`: a reserved band
/// for the hover control bar, then the fixed-geometry caption band (or the idle
/// pill). The caption band's frame comes ONLY from settings — while a meeting is
/// active the panel never resizes, no matter what the text does.
private struct OverlayRootView: View {
    @ObservedObject var model: OverlayModel
    let actions: OverlayActions

    private let controlBandHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            // The control bar is ALWAYS laid out (only faded on hover) so the overlay's
            // resting width never changes when it appears. Otherwise a narrow idle pill
            // would re-size + re-centre every time the wider bar faded in, making it
            // impossible to grab and drag into place before a meeting starts.
            ZStack {
                OverlayControlBar(model: model, actions: actions)
                    .opacity(model.showControls ? 1 : 0)
                    .allowsHitTesting(model.showControls)
            }
            .frame(height: controlBandHeight)

            content
        }
        .fixedSize()
        .animation(model.reduceMotion ? nil : .easeOut(duration: CaptionTheme.Metric.controlsDuration), value: model.showControls)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: OverlaySizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(OverlaySizeKey.self) { actions.onSize($0) }
    }

    /// Show the caption band whenever a meeting is running (warming counts — the
    /// band doubles as the "captions will appear here" affordance) or content
    /// remains on screen (e.g. pinned for reading after the meeting ended).
    private var showBand: Bool {
        model.listenState == .listening || model.listenState == .warming
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
                .frame(width: CaptionTheme.Metric.overlayTotalWidth, alignment: .center)
        }
    }

    /// The lines actually drawn, in one continuous ForEach: history first, then
    /// the current slot. Sharing ONE identity space means the roll-up (slot →
    /// history) is a smooth position change of the SAME element — never a
    /// remove/insert jump. The interim slot is hidden when the user chose
    /// `interimStyle == .hidden`.
    private var bandLines: [BandLine] {
        var arr = model.band.visibleCommitted
        if let slot = model.band.visibleSlot,
           slot.isFinal || model.interimStyle == .markedWithCaret {
            arr.append(slot)
        }
        return arr
    }

    private var captionBand: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Banner OUTSIDE the fixed content area: pinning is a deliberate act,
            // the one-time height change is fine (and the banner never clips).
            if model.band.isPinned {
                PinnedBanner(pending: model.band.pendingWhilePinned)
            }
            bandContent
                .frame(width: CaptionTheme.Metric.overlayMaxWidth, alignment: .bottomLeading)
        }
        .padding(.horizontal, CaptionTheme.Metric.overlayScrimHPadding)
        .padding(.top, 14)
        .padding(.bottom, 15)
        .scrim(opacity: model.opacity, pinned: model.band.isPinned)
    }

    /// Height of the band's scroll viewport — fixed by settings, never by text.
    private var bandViewportHeight: CGFloat {
        CaptionTheme.bandContentHeight(
            fontSize: model.fontSize,
            historyLines: model.historyLineCount,
            secondLine: model.showSecondLine)
    }

    /// The caption band: a FIXED-height window onto text that is never truncated.
    ///
    /// Anchored to the bottom, so the newest words hold a constant position and
    /// anything that no longer fits scrolls up out of view rather than being
    /// replaced by an ellipsis — it is all still there. Scrolling back is
    /// deliberately gated on the pin (⌃⌥P): unpinned, the band stays purely
    /// click-through so it never steals a scroll meant for the app behind it;
    /// pinned, the content is frozen anyway, which is exactly when you want to
    /// read back through it.
    @ViewBuilder
    private var bandContent: some View {
        ScrollView(.vertical) {
            bandStack
                // Short content still hugs the bottom of the window.
                .frame(minHeight: bandViewportHeight, alignment: .bottomLeading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDisabled(!model.isPinned)
        .scrollIndicators(model.isPinned ? .automatic : .never)
        .frame(height: bandViewportHeight)
    }

    @ViewBuilder
    private var bandStack: some View {
        let lines = bandLines
        // MUST stay `Metric.unitSpacing` — `bandContentHeight` budgets exactly
        // this much between units, so the viewport shows whole units.
        VStack(alignment: .leading, spacing: CaptionTheme.Metric.unitSpacing) {
            if lines.isEmpty {
                bandStatusRow
            }
            ForEach(lines) { line in
                BandLineView(
                    line: line,
                    fontSize: model.fontSize,
                    primaryOnTop: model.primaryLineOnTop,
                    showSecond: model.showSecondLine,
                    showSpeakerSlot: model.showSpeakerSlot,
                    reduceMotion: model.reduceMotion
                )
                .transition(model.reduceMotion
                            ? .identity
                            : .opacity.animation(.easeOut(duration: CaptionTheme.Metric.evictDuration)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .animation(model.reduceMotion ? nil : .easeOut(duration: CaptionTheme.Metric.enterDuration),
                   value: model.band)
    }

    /// Small status row inside the (otherwise empty) band, so a fresh meeting
    /// shows where captions will appear and whether the model is still loading.
    private var bandStatusRow: some View {
        HStack(spacing: 8) {
            switch model.listenState {
            case .warming:
                BreathingDot(color: CaptionTheme.Palette.accentSystem, animated: !model.reduceMotion, size: 6)
                    .frame(width: 6, height: 6)
                Text("模型載入中…可先開始說話（開頭不會漏）")
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

/// Hosting view that only "grabs" mouse clicks in the top control-bar band (when
/// controls are showing); everything else returns nil so clicks fall through to the
/// app below. Pure passthrough is still handled by `ignoresMouseEvents` when not
/// hovering.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveTopInset: CGFloat = 40
    var controlsVisible: () -> Bool = { false }
    /// Pinned = "read mode": the caption area accepts the scroll wheel so you can
    /// go back through what was said. Unpinned it stays fully click-through, so a
    /// scroll aimed at the app behind never lands on the captions by accident.
    var readModeActive: () -> Bool = { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if readModeActive() { return super.hitTest(point) }
        guard controlsVisible() else { return nil }
        // Bottom-left origin: the control band sits at the TOP (high y).
        if point.y >= bounds.height - interactiveTopInset {
            return super.hitTest(point)
        }
        return nil
    }
}

// MARK: - Overlay controller (NSPanel manager)

/// Manages the floating-caption `NSPanel`: always on top (incl. full-screen apps),
/// click-through except over the hover control bar, draggable with a persisted
/// position, and auto-sized to its caption content.
@MainActor
final class OverlayController {
    let model = OverlayModel()

    /// Caller hooks: persist a moved position / a font step / a reset-to-defaults.
    var onPositionChanged: ((CGPoint) -> Void)?
    var onFontStep: ((Int) -> Void)?
    var onReset: (() -> Void)?

    private var panel: NSPanel?
    private var hostingView: PassthroughHostingView<OverlayRootView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var clickThroughEnabled = true
    private var isHovering = false
    private var overlayAnchor: CGPoint?   // persisted TOP-CENTRE anchor (nil = default)
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
        overlayAnchor = s.overlayPosition
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
        hosting.controlsVisible = { [weak self] in self?.model.showControls ?? false }
        hosting.readModeActive = { [weak self] in self?.model.isPinned ?? false }
        self.hostingView = hosting

        let panel = NSPanel(
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
            onDrag: { [weak self] in self?.dragChanged($0) },
            onDragEnd: { [weak self] in self?.dragEnded() },
            onPin: { [weak self] in self?.model.togglePin() },
            onCopy: { [weak self] in self?.copyLatest() },
            onFont: { [weak self] in self?.onFontStep?($0) },
            onReset: { [weak self] in self?.onReset?() }
        )
    }

    /// Resize the panel to fit its content while keeping the user's **top-centre
    /// anchor** fixed: the box grows downward and stays put horizontally no matter
    /// how the content width/height change (new line, idle pill ↔ caption, pin
    /// banner). Falls back to the default bottom-centre placement when un-dragged.
    private func applyContentSize(_ size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        lastContentSize = size
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let anchor = clampAnchor(overlayAnchor ?? defaultAnchor(size: size, in: vf),
                                 size: size, in: vf)
        // `anchor` is the TOP-CENTRE of the window; derive the bottom-left origin.
        let origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Default placement as a top-centre anchor: horizontally centred, sitting
    /// `overlayBottomFraction` up from the bottom of the visible frame.
    private func defaultAnchor(size: CGSize, in vf: NSRect) -> CGPoint {
        let bottomY = vf.minY + vf.height * CaptionTheme.Metric.overlayBottomFraction
        return CGPoint(x: vf.midX, y: bottomY + size.height)
    }

    /// Keep a saved top-centre anchor inside the visible frame — **nudged back in,
    /// never discarded** — so the overlay can't drift off-screen or snap back to the
    /// centre after a resolution / display / Space change.
    private func clampAnchor(_ anchor: CGPoint, size: CGSize, in vf: NSRect) -> CGPoint {
        let halfW = size.width / 2
        let x = min(max(anchor.x, vf.minX + halfW), vf.maxX - halfW)
        // y is the window's top edge; keep the whole height within the visible frame.
        let y = min(max(anchor.y, vf.minY + size.height), vf.maxY)
        return CGPoint(x: x, y: y)
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
        panel.setFrameOrigin(newOrigin)
        // Track the live position as a top-centre anchor so content-size updates
        // mid-drag stay pinned to where the user is dragging.
        let size = panel.frame.size
        overlayAnchor = CGPoint(x: newOrigin.x + size.width / 2, y: newOrigin.y + size.height)
    }

    private func dragEnded() {
        guard let panel else { return }
        dragMouseStart = nil
        dragOriginStart = nil
        let f = panel.frame
        lastContentSize = f.size
        let anchor = CGPoint(x: f.midX, y: f.maxY)   // persist the top-centre anchor
        overlayAnchor = anchor
        onPositionChanged?(anchor)
    }

    // MARK: Copy

    private func copyLatest() {
        guard let line = model.latest else { return }
        var text = line.english
        if let zh = line.chinese, !zh.isEmpty { text += "\n" + zh }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
        // The hover control bar lives in the TOP band of the panel; ONLY that region
        // should capture clicks. Everywhere else (the caption text) stays fully
        // click-through, so you can keep clicking Zoom/the browser behind it.
        let band = NSRect(x: frame.minX - 8, y: frame.maxY - 52, width: frame.width + 16, height: 60)
        let overBand = overPanel && band.contains(mouse)
        if overPanel != isHovering {
            isHovering = overPanel
            model.showControls = overPanel
        }
        // `ignoresMouseEvents == true` means click-through; capture only over the
        // control band — or, while pinned, anywhere on the panel, so the frozen
        // captions can be scrolled back through (`PassthroughHostingView`).
        panel.ignoresMouseEvents = !(overBand || (model.isPinned && overPanel))
    }

    private func setHovering(_ inside: Bool) {
        isHovering = inside
        if !inside {
            model.showControls = false
            if clickThroughEnabled { panel?.ignoresMouseEvents = true }
        }
    }
}
