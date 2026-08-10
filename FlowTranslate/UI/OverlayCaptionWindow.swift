import SwiftUI
import AppKit
import FlowTranslateCore
import os

// MARK: - Overlay view model

/// Listening state mirrored from the app's `ASRState` so the idle status pill can
/// reflect reality (listening / loading / warming / not listening) instead of
/// always claiming "Listening" even when stopped or still loading the model.
enum OverlayListenState { case idle, loading, warming, listening }

/// Observable content + presentation state for the floating caption overlay.
/// Content lives in `CaptionBandState` (pure, unit-tested core logic): a current
/// utterance **slot** that morphs in place from interim to finalized (same view
/// identity → no jump), plus rolled-up history lines.
///
/// The band is a fixed size from the settings and pinned by its bottom edge, so
/// no edge moves while captions stream: the live utterance starts on a fixed line
/// and grows downward into room reserved for it, and the finalized lines above
/// step up a whole unit at a time.
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
                     speakerLabel: String? = nil,
                     provisional: [UUID: String] = [:]) {
        band.commit(utteranceId: utteranceId, source: source,
                    sentences: sentences, expectsTranslation: expectsTranslation,
                    speakerLabel: speakerLabel, provisional: provisional)
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

    func clear() {
        band.clear()
    }

    /// Latest finalized line (used by the copy action).
    var latest: BandLine? { band.latestFinal }
}

/// Callbacks the SwiftUI overlay invokes back into the `OverlayController`.
struct OverlayActions {
    var onSize: (CGSize) -> Void = { _ in }
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
        // Room below for the shadow, which falls 4 pt down with an 11 pt blur.
        // The control strip is above the scrim again, so there is nothing under
        // it to catch the shadow and the panel's own edge would clip it.
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

private extension View {
    /// Let this line wrap, up to `rows`.
    ///
    /// **Wrapping only — the type size is never touched.** A previous version
    /// shrank a long caption to fit its rows, and the size is the user's setting:
    /// a caption that quietly gets smaller when a sentence runs long is the app
    /// overruling the one thing about the overlay they chose by hand. The row
    /// allowance is what gives instead, and it is generous enough
    /// (`CaptionTheme.liveRecognitionRows`) that the limit is a backstop rather
    /// than something a sentence meets.
    func wrapping(upTo rows: Int) -> some View {
        lineLimit(rows)
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
    /// Rows this line may wrap to.
    let recognitionRows: Int

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

    private var speakerSlotWidth: CGFloat {
        CaptionTheme.speakerSlotWidth(labelSize: CaptionTheme.speakerLabelSize(fontSize))
    }

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
    /// Reserving rows *inside* the unit was tried and is what put a gap between
    /// the original and its translation: a three-row area holding a one-row
    /// sentence shows the two rows it is not using, and they land in the one
    /// place a reader reads across. Where the slack goes instead is
    /// `liveRegion`'s problem, and it puts it above the whole unit.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CaptionTheme.Metric.gutterSpacing) {
            dot
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
            speakerLabel
            VStack(alignment: .leading, spacing: CaptionTheme.Metric.rowGap) {
                Group {
                    if englishOnTop {
                        englishRow(font: CaptionTheme.primaryFont(fontSize), color: topColor,
                                   rows: recognitionRows)
                    } else {
                        Text(secondRowText)
                            .font(CaptionTheme.primaryFont(fontSize).weight(.semibold))
                            .contentTransition(reduceMotion ? .identity : .interpolate)
                            .foregroundStyle(translation == nil ? CaptionTheme.Palette.inkTertiary : topColor)
                            .wrapping(upTo: recognitionRows)
                    }
                }

                if showSecondRow {
                    Group {
                        if englishOnTop {
                            Text(secondRowText)
                                .font(CaptionTheme.translationFont(fontSize))
                                .contentTransition(reduceMotion ? .identity : .interpolate)
                                .foregroundStyle(bottomColor)
                                .wrapping(upTo: CaptionTheme.translationRows)
                        } else {
                            englishRow(font: CaptionTheme.translationFont(fontSize),
                                       color: bottomEnglishColor,
                                       rows: CaptionTheme.translationRows)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(SpeakerName.wrapping(line.speakerLabel ?? ""))
                .font(.system(size: CaptionTheme.speakerLabelSize(fontSize), weight: .bold))
                // Two lines, broken at the join. One line could not fit the full
                // name in a column the band reserves on every row, and showing
                // the model half alone stopped being unique the moment the name
                // pools ran out.
                .multilineTextAlignment(.leading)
                // `inkSecondary`, not `inkTertiary`: the speaker is a cue you
                // actually read, and the weakest ink is near-invisible on the
                // scrim at label size.
                .foregroundStyle(CaptionTheme.Palette.inkSecondary)
                .lineLimit(2)
                // `minWidth`, not `width`, and `fixedSize` so the label wins.
                //
                // The slot is measured against every name the generator can
                // produce, so in principle nothing overflows it. In practice a
                // fixed width plus tail truncation means that if anything ever
                // *does* hand this row a longer label — a full `Claude Mango`
                // from a path that should have sent the short form, a restored
                // line, a name form added later — the name is silently cut, and a
                // cut name is worse than no name: `Claude M…` and `Claude P…`
                // read as the same speaker.
                //
                // A wider column instead shifts the text by a few points on the
                // rows that carry the long label, which is visible, harmless, and
                // self-reporting. Everything else in this band is built so text
                // is never truncated; this was the one place it could be.
                // `fixedSize()` on BOTH axes, which is the whole point.
                // `vertical: false` left the height to the parent, and the row's
                // height comes from a one-line caption — so the two-line label was
                // proposed a one-line box and collapsed straight back to one
                // truncated line. The hard newline was there; there was nowhere
                // to put it.
                .fixedSize()
                .frame(minWidth: speakerSlotWidth, alignment: .leading)
        }
    }

    /// The recognition-text row: caret + dotted underline live HERE (wherever the
    /// English sits), never on a possibly-empty translation row.
    ///
    /// Bounded to `rows` rather than allowed to wrap freely: text taking as many
    /// lines as it needs makes the band scroll, which puts half a glyph at the top
    /// of the box. The allowance is sized so a sentence wraps inside it.
    private func englishRow(font: Font, color: Color, rows: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(line.english)
                // One weight for every state. Medium→semibold on finalize was the
                // worst of the jumps: semibold is wider, so a sentence could
                // re-wrap the moment it ended and shove the whole band upward.
                .font(font.weight(.semibold))
                .contentTransition(reduceMotion ? .identity : .interpolate)
                .foregroundStyle(color)
                .wrapping(upTo: rows)
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

private struct OverlaySizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Top-level SwiftUI content hosted inside the floating `NSPanel`: a reserved
/// band for the hover control bar, then the caption band (or the idle pill).
///
/// The control bar is at the **top**. It sat at the bottom for a while, on the
/// reasoning that the panel is anchored by its bottom edge so only the bottom is
/// guaranteed still — but the band is a fixed size now, so the top edge does not
/// move either and that reasoning no longer buys anything.
private struct OverlayRootView: View {
    @ObservedObject var model: OverlayModel
    let actions: OverlayActions

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
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: OverlaySizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(OverlaySizeKey.self) { actions.onSize($0) }
        // **Anchored to the bottom of the panel, and this is the fix for the
        // last of the jumping.** Resizing the window is a round trip: SwiftUI
        // lays the content out, reports its size through the preference above,
        // and the controller sets the panel frame — on the *next* turn of the
        // run loop. For that one turn the content and the window disagree about
        // how tall they are, and `NSHostingView` resolves a `fixedSize` content
        // smaller or larger than its bounds by **centring** it. So every single
        // change of height moved the content down by half the difference and
        // back again, which is a flicker at the bottom edge and at the live
        // line's first row — the two places that are supposed to be nailed down.
        //
        // Pinning the content to the bottom makes the transient land entirely at
        // the top, where the geometry already says movement is allowed. The
        // frame goes **after** the preference so the reported size is still the
        // content's own; putting it before would report the panel's bounds and
        // feed the sizing loop its own output.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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

    /// The finalized lines, oldest first. These are the ones that move.
    private var historyLines: [BandLine] { model.band.visibleCommitted }

    /// The utterance being spoken — or the one that just finished, which stays in
    /// the slot until the next begins. Nil when the user hid the interim line.
    private var liveLine: BandLine? {
        guard let slot = model.band.visibleSlot,
              slot.isFinal || model.interimStyle == .markedWithCaret
        else { return nil }
        return slot
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
        // Small, because the live area already carries its own slack underneath
        // the translation — see `liveRegion`. Adding the old 15 pt on top of that
        // made the reserved rows read as a gap rather than as padding.
        .padding(.bottom, 6)
        // **Inside the box, in the one corner that never moves.**
        //
        // The panel is pinned by its bottom edge and its width is a constant, so
        // the bottom-right corner is fixed in both axes while the top edge follows
        // the history. A control anywhere else travels when the box grows — and a
        // control that moves between the user seeing it and pressing it is a
        // control that cannot be pressed. `.overlay` rather than a row in the
        // stack, so the captions keep their full width and the box its height.
        .overlay(alignment: .bottomTrailing) {
            OverlayControlBar(model: model, actions: actions)
                .opacity(model.showControls ? 1 : 0)
                .allowsHitTesting(model.showControls)
                .padding(.trailing, 6)
                .padding(.bottom, 4)
        }
        .scrim(opacity: model.opacity, pinned: model.band.isPinned)
    }

    /// Height reserved for the live utterance. Never changes.
    private var liveRegionHeight: CGFloat {
        CaptionTheme.liveUnitHeight(model.fontSize, secondLine: model.showSecondLine)
    }

    /// The caption band: **the live utterance starts at a fixed line, and the top
    /// edge sits on top of the oldest one.**
    ///
    /// Two regions, and the boundary between them is the only geometry that
    /// matters. The sentence being spoken is the one you are reading, so it is
    /// given its own reserved area at the foot of the box, top-aligned: its first
    /// row lands on the same line whatever it does next, and it grows *downward*
    /// into space that was already set aside for it. Nothing below it, and no
    /// edge of the window, moves while somebody is talking.
    ///
    /// The finalized lines sit above it and take **their own height**, so the top
    /// of the box lands on the top of the oldest one and there is no reserved
    /// blank above it. Combined with the bottom-pinned panel, that means only the
    /// top edge ever moves, and only when a sentence finalizes or is evicted —
    /// never while one is being spoken, because nothing in this half changes then.
    ///
    /// One stack, bottom-anchored, could not do this: the live line's *last* row
    /// would be the fixed one, so its first row jumped up a row every time the
    /// sentence wrapped, taking the whole history with it.
    private var bandContent: some View {
        VStack(alignment: .leading, spacing: CaptionTheme.Metric.unitSpacing) {
            // Guarded on the lines, not the setting: an empty region is still a
            // `VStack` child, and its spacing would hold a 12 pt gap above the
            // live line for a history that does not exist yet.
            if !historyLines.isEmpty {
                historyRegion
            }
            liveRegion
        }
        // **No animation on the band's own height.** There was one, easing the
        // layout over 180 ms — which meant the content's height changed on every
        // frame of it, and the window chased each of those a run loop behind. Ten
        // resizes, ten frames of the content and the panel disagreeing, for one
        // sentence rolling up. The height change is instantaneous now: one
        // resize, one frame, absorbed at the top by the bottom anchor in
        // `OverlayRootView`. The per-line opacity transitions below stay, because
        // fading a line in and out costs no layout.
    }

    /// Finalized lines, sized to themselves and stacked above the live utterance.
    ///
    /// **No fixed height and no scroll view.** Reserving the rows these lines are
    /// allowed to use meant the box was always as tall as its worst case — three
    /// rows per sentence, when most take one — so it stood in a block of empty
    /// scrim that never went away. Letting the stack size itself puts the top of
    /// the box on the top of the oldest caption instead.
    ///
    /// This does not bring back the moving box it replaced. That version measured
    /// the *live* line, which re-wraps several times a second; this half only
    /// changes when a sentence finalizes or is evicted. And the panel is pinned by
    /// its bottom edge with a constant width, so a change here can only move the
    /// top.
    private var historyRegion: some View {
        VStack(alignment: .leading, spacing: CaptionTheme.Metric.unitSpacing) {
            ForEach(historyLines) { line in
                bandLineView(line, recognitionRows: CaptionTheme.historyRecognitionRows)
                    // Removal is instant, and it has to be for the floor below to
                    // mean anything. A removal transition keeps the leaving view
                    // in the layout for its whole duration, so a symmetric fade
                    // held one extra line for 250 ms at every commit — which the
                    // high-water mark would then adopt as the new floor, for a
                    // line that no longer exists. Insertion may fade: the arriving
                    // line's space is needed immediately either way.
                    .transition(model.reduceMotion
                                ? .identity
                                : .asymmetric(
                                    insertion: .opacity.animation(
                                        .easeOut(duration: CaptionTheme.Metric.evictDuration)),
                                    removal: .identity))
            }
        }
        // **Nothing reserves height here.** The stack is exactly as tall as the
        // lines in it, so the top edge sits on the top of the oldest caption and
        // follows it as history arrives, is evicted, or the visible-line count,
        // font size and second-caption switch change.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The utterance being spoken: a **fixed** area with the content at the
    /// **top** of it.
    ///
    /// Both choices are forced by the requirements below; every other arrangement
    /// breaks one of them.
    ///
    /// - The bottom edge is fixed and the top follows the history, so the box's
    ///   height is `history + live`.
    /// - The live sentence must start on a fixed line. Its top is therefore a
    ///   fixed distance above the bottom edge — which means **this area's height
    ///   cannot depend on the sentence**. Hence `height`, not `minHeight`.
    /// - It is `topLeading` because that fixed line is the *first* row. Bottom
    ///   alignment holds the last row instead, which reads as the sentence
    ///   crawling upward and leaves the unused rows above it — a block of blank
    ///   between the history and the live line.
    /// - The recognition text and its translation are adjacent inside the unit,
    ///   with nothing reserved between them, so there is no gap where a reader
    ///   reads across.
    ///
    /// All four together make the consequence unavoidable: a reserved area
    /// holding a shorter sentence has slack, and with the content at the top that
    /// slack is **below the translation** — the only place left for it. It reads
    /// as padding above the band's lower border, which is why the band's own
    /// bottom padding is small.
    @ViewBuilder
    private var liveRegion: some View {
        Group {
            if let live = liveLine {
                bandLineView(live, recognitionRows: CaptionTheme.liveRecognitionRows)
            } else {
                bandStatusRow
            }
        }
        .frame(height: liveRegionHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bandLineView(
        _ line: BandLine, recognitionRows: Int
    ) -> some View {
        BandLineView(
            line: line,
            fontSize: model.fontSize,
            primaryOnTop: model.primaryLineOnTop,
            showSecond: model.showSecondLine,
            showSpeakerSlot: model.showSpeakerSlot,
            reduceMotion: model.reduceMotion,
            recognitionRows: recognitionRows
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

/// Hosting view that only "grabs" mouse clicks in the control-bar band (when
/// controls are showing); everything else returns nil so clicks fall through to the
/// app below. Pure passthrough is still handled by `ignoresMouseEvents` when not
/// hovering.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var controlsVisible: () -> Bool = { false }

    /// Only the controls' corner is ever interactive.
    ///
    /// Everything else — every caption, pinned or not — passes the click straight
    /// through to whatever is behind the overlay, which is the whole point of a
    /// click-through caption band.
    override func hitTest(_ point: NSPoint) -> NSView? {
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
        // Adopt the stored anchor only when it actually changed — i.e. when the
        // user dragged the overlay.
        //
        // `applyContentSize` shifts the live anchor on every reflow so the bottom
        // edge holds, and re-reading the persisted top-centre value here undid
        // that. Any unrelated settings write would do it: a font step, a gain
        // slider, an overlay-opacity drag — each one snapped the box back and
        // moved the line being read, which is precisely what holding the bottom
        // edge exists to prevent.
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
        hosting.controlsVisible = { [weak self] in self?.model.showControls ?? false }
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
            onDrag: { [weak self] in self?.dragChanged($0) },
            onDragEnd: { [weak self] in self?.dragEnded() },
            onReset: { [weak self] in self?.onReset?() }
        )
    }

    /// Resize the panel to fit its content while keeping the user's **bottom-centre
    /// anchor** fixed: the box grows upward and stays put horizontally no matter
    /// how the content width/height change (new line, idle pill ↔ caption, pin
    /// banner). Falls back to the default bottom-centre placement when un-dragged.
    ///
    /// Every edge but the top is therefore fixed by construction: `origin.y` is
    /// the anchor itself, and `origin.x` is the anchor minus half a width that
    /// `OverlayRootView` holds constant. Only `maxY` — the top — follows the text.
    private func applyContentSize(_ size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        lastContentSize = size
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame

        let bottom = pinnedBottom ?? defaultBottom(in: vf)
        // The bottom edge IS the origin's y, so it does not move when the height
        // changes. Only the top boundary follows the text.
        var origin = CGPoint(x: bottom.x - size.width / 2, y: bottom.y)
        // Nudged back into the visible frame, never discarded, so the overlay
        // cannot drift off-screen or snap to the centre after a resolution,
        // display or Space change.
        origin.x = min(max(origin.x, vf.minX + 8), max(vf.minX + 8, vf.maxX - size.width - 8))
        // **Only the lower bound.** An upper one — `min(origin.y, vf.maxY -
        // size.height - 8)` — inverts the geometry: once the box is tall enough
        // for it to bite it pins `maxY` to the screen edge, so every caption that
        // makes the box taller pushes the **bottom** down. That engages exactly
        // when the box is doing what it is supposed to do. The height is bounded
        // by `historyLimit` anyway, so dropping it costs nothing.
        origin.y = max(origin.y, vf.minY + 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
        panel.setFrameOrigin(newOrigin)
        // Track the live position as a bottom edge, so a content-size update
        // mid-drag stays pinned to where the user is dragging.
        let size = panel.frame.size
        pinnedBottom = CGPoint(x: newOrigin.x + size.width / 2, y: newOrigin.y)
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
        // `ignoresMouseEvents == true` means click-through; capture only over the
        // control strip. Pinning no longer makes the caption area interactive:
        // there is nothing to scroll now that every unit sits in its own slot,
        // and swallowing clicks over frozen captions is the opposite of what a
        // click-through overlay is for.
        panel.ignoresMouseEvents = !overBand
    }

    private func setHovering(_ inside: Bool) {
        isHovering = inside
        if !inside {
            model.showControls = false
            if clickThroughEnabled { panel?.ignoresMouseEvents = true }
        }
    }
}
