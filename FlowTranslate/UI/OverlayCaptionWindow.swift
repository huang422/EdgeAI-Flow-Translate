import SwiftUI
import AppKit
import FlowTranslateCore

// MARK: - Overlay view model

/// Listening state mirrored from the app's `ASRState` so the idle status pill can
/// reflect reality (listening / loading / not listening) instead of always
/// claiming "Listening" even when stopped.
enum OverlayListenState { case idle, loading, listening }

/// Observable content + presentation state for the floating caption overlay.
/// `lines` are finalized caption units (English + translation, with source);
/// `interim` is the in-progress recognition line (English only, no translation yet).
@MainActor
final class OverlayModel: ObservableObject {
    // Content
    @Published var lines: [CaptionLine] = [] {
        didSet { if isPinned { pendingCount = max(0, lines.count - pinnedSnapshot.count) } }
    }
    @Published var interim: String = ""
    @Published var interimChinese: String = ""   // live translation of the in-progress line
    @Published var interimSource: AudioSourceType = .system

    /// Mirrors the app's ASR state so the idle pill reflects whether we are really
    /// listening, loading, or stopped (idle) — never a stale "Listening".
    @Published var listenState: OverlayListenState = .idle

    // Interaction state
    @Published var isPinned = false
    @Published var pendingCount = 0
    @Published var showControls = false
    private var pinnedSnapshot: [CaptionLine] = []

    // Presentation (mirrored from CaptionSettings)
    @Published var fontSize: Double = 16
    @Published var opacity: Double = 0.66
    @Published var showSecondLine = true
    @Published var primaryLineOnTop: PrimaryLine = .original
    @Published var historyLineCount: Int = 1
    @Published var interimStyle: InterimStyle = .dimmedWithCaret
    @Published var reduceMotion = false

    /// Finalized units actually drawn: the latest plus `historyLineCount` of history
    /// (or the frozen snapshot while pinned).
    var visible: [CaptionLine] {
        let source = isPinned ? pinnedSnapshot : lines
        return Array(source.suffix(historyLineCount + 1))
    }

    /// Whether to show the interim line right now.
    var interimVisible: Bool {
        interimStyle == .dimmedWithCaret && !isPinned
            && !interim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether there is any caption to show (vs. the idle "listening" pill).
    var hasContent: Bool { !visible.isEmpty || interimVisible || isPinned }

    func togglePin() {
        isPinned.toggle()
        if isPinned {
            pinnedSnapshot = lines
            pendingCount = 0
        } else {
            pendingCount = 0
            interim = ""
        }
    }

    func clear() {
        lines = []
        interim = ""
        interimChinese = ""
        isPinned = false
        pendingCount = 0
        pinnedSnapshot = []
    }

    /// Latest finalized unit (used by the copy action).
    var latest: CaptionLine? { lines.last }
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
        .shadow(color: .black.opacity(0.5), radius: 22, x: 0, y: 16)
    }
}

/// A source-colour dot; the latest finalized / listening dot gets a soft glow.
struct SourceDot: View {
    let color: Color
    var glow: Bool = false
    var size: CGFloat = 6
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow ? color.opacity(0.6) : .clear, radius: glow ? 4 : 0)
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

// MARK: - Caption units

/// One finalized caption unit: source dot + primary line (bright) + secondary line
/// (dim, indented). Which language is primary depends on `primaryOnTop`.
private struct CaptionUnit: View {
    let line: CaptionLine
    let fontSize: Double
    let primaryOnTop: PrimaryLine
    let showSecond: Bool
    var isLatest: Bool

    private var original: String { line.english }
    private var translation: String? {
        guard let t = line.chinese?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private var topText: String {
        if !showSecond || translation == nil { return original }
        return primaryOnTop == .original ? original : translation!
    }
    private var bottomText: String? {
        guard showSecond, let t = translation else { return nil }
        return primaryOnTop == .original ? t : original
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SourceDot(color: CaptionTheme.Palette.sourceDot(line.source), glow: isLatest)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
                Text(topText)
                    .font(CaptionTheme.primaryFont(fontSize))
                    .foregroundStyle(isLatest ? Color(hex: 0xF7F8FA) : CaptionTheme.Palette.inkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bottom = bottomText {
                Text(bottom)
                    .font(CaptionTheme.translationFont(fontSize))
                    .foregroundStyle(CaptionTheme.Palette.inkTranslation)
                    .padding(.leading, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The in-progress recognition line: English only, dimmed, dotted underline,
/// blinking caret, red breathing dot.
private struct InterimLine: View {
    let text: String
    let chinese: String
    let showSecond: Bool
    let source: AudioSourceType
    let fontSize: Double
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BreathingDot(color: CaptionTheme.Palette.stopRec, animated: !reduceMotion, size: 6)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(text)
                        .font(CaptionTheme.primaryFont(fontSize).weight(.medium))
                        .overlay(alignment: .bottom) {
                            DottedUnderline()
                                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2.5]))
                                .foregroundStyle(Color(hex: 0xF5F5F7).opacity(0.3))
                                .frame(height: 1.5)
                                .offset(y: 3)
                        }
                    BlinkingCaret(height: fontSize * 0.95, animated: !reduceMotion)
                }
                .foregroundStyle(Color(hex: 0xF5F5F7).opacity(CaptionTheme.Metric.interimOpacity))
                .fixedSize(horizontal: false, vertical: true)
            }
            // Live translation of the in-progress line (when the engine provides it).
            if showSecond, !chinese.isEmpty {
                Text(chinese)
                    .font(CaptionTheme.translationFont(fontSize))
                    .foregroundStyle(CaptionTheme.Palette.inkTranslation.opacity(0.72))
                    .padding(.leading, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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
        case .loading:
            BreathingDot(color: CaptionTheme.Palette.accentSystem, size: 7).frame(width: 7, height: 7)
        case .idle:
            Circle().fill(CaptionTheme.Palette.inkTertiary).frame(width: 7, height: 7)
        }
    }

    private var text: String {
        switch state {
        case .listening: return "聆聽中… Listening"
        case .loading:   return "載入中… Loading"
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
/// for the hover control bar, then the caption scrim (or the idle pill).
private struct OverlayRootView: View {
    @ObservedObject var model: OverlayModel
    let actions: OverlayActions

    private let bandHeight: CGFloat = 32

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
            .frame(height: bandHeight)

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

    @ViewBuilder
    private var content: some View {
        if model.hasContent {
            captionStack
                .frame(width: CaptionTheme.Metric.overlayMaxWidth, alignment: .leading)
                .padding(.horizontal, CaptionTheme.Metric.overlayScrimHPadding)
                .padding(.top, 16)
                .padding(.bottom, 17)
                .scrim(opacity: model.opacity, pinned: model.isPinned)
        } else {
            // Lay the idle pill out at the full caption width (scrim stays pill-sized,
            // centred) so the centre-anchored window keeps a constant width and never
            // shifts horizontally when content toggles idle ↔ caption.
            ListeningPill(state: model.listenState)
                .frame(width: CaptionTheme.Metric.overlayTotalWidth, alignment: .center)
        }
    }

    private var captionStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPinned { PinnedBanner(pending: model.pendingCount) }
            ForEach(Array(model.visible.enumerated()), id: \.element.id) { idx, line in
                CaptionUnit(
                    line: line,
                    fontSize: model.fontSize,
                    primaryOnTop: model.primaryLineOnTop,
                    showSecond: model.showSecondLine,
                    isLatest: idx == model.visible.count - 1
                )
                .opacity(idx == model.visible.count - 1 ? 1.0 : CaptionTheme.Metric.historyOpacity)
                .transition(model.reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
            }
            if model.interimVisible {
                InterimLine(text: model.interim, chinese: model.interimChinese,
                            showSecond: model.showSecondLine, source: model.interimSource,
                            fontSize: model.fontSize, reduceMotion: model.reduceMotion)
            }
        }
        .animation(model.reduceMotion ? nil : .easeOut(duration: CaptionTheme.Metric.enterDuration), value: model.lines)
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

    override func hitTest(_ point: NSPoint) -> NSView? {
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
        // `ignoresMouseEvents == true` means click-through; capture only over the band.
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
