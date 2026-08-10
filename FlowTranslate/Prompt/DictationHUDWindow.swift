import AppKit
import SwiftUI
import FlowTranslateCore

/// A small status panel shown during hotkey dictation.
///
/// Follows the same window contract as the caption overlay, because it is the
/// same situation: a floating panel that has to stay visible over *another*
/// application while this one is in the background. Each of these flags decides
/// whether the panel is on screen at all.
///
/// - **Never hide when the app deactivates.** `NSPanel` defaults
///   `hidesOnDeactivate` to `true`, and the hotkey exists precisely to be pressed
///   while another app is frontmost.
/// - **Stay above full-screen apps, on every Space.** Same level and collection
///   behaviour as the overlay.
/// - **Be movable.** It is pinned beside the pointer, which is often exactly
///   where the user is about to type, so it can be dragged by its handle and
///   remembers where it was put.
/// - **Never steal keyboard focus.** The target application has to keep it, or
///   the synthesized ⌘V lands in the wrong window. Hence `.nonactivatingPanel`,
///   and a drag driven by absolute mouse position rather than by making the panel
///   key.
@MainActor
final class DictationHUDWindow {

    private var panel: NSPanel?
    private let model = HUDModel()
    /// Where the user last dragged it — the panel's bottom-left origin in screen
    /// coordinates. `nil` until they move it, and then it wins over the pointer.
    private var pinnedOrigin: NSPoint?

    /// Mouse and window positions at the start of the current drag.
    private var dragMouseStart: NSPoint?
    private var dragOriginStart: NSPoint?

    /// Reports a drag so the caller can persist the position across launches.
    var onPositionChanged: ((NSPoint) -> Void)?
    /// Reads the current insert mode, and reports a change made from the panel.
    ///
    /// On the HUD rather than only in Settings because this is the one decision
    /// whose right answer changes per dictation — a commit message and a coding
    /// task want different output, and Settings is three clicks and a context
    /// switch away from a panel that is on screen for ten seconds.
    var insertMode: (() -> PromptQuickInsertMode)?
    var onInsertModeChanged: ((PromptQuickInsertMode) -> Void)?
    /// Abandon the session. The ✕ in the header calls this.
    ///
    /// The one cancel path that depends on nothing: no permission, no hot-key
    /// registration, no guess about which application is frontmost. ⎋ is the
    /// shortcut for it, and this is what makes ⎋ optional.
    var onCancel: (() -> Void)?

    static let width: CGFloat = 320

    /// Restore a remembered position. Call before the first `show`.
    func restore(origin: NSPoint?) {
        pinnedOrigin = origin
    }

    func show(near screenPoint: NSPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Re-read rather than trusting the panel's copy: the mode may have been
        // changed in Settings since the last dictation.
        model.mode = insertMode?() ?? model.mode
        panel.setContentSize(NSSize(width: Self.width, height: model.preferredHeight))
        position(panel, near: screenPoint)
        panel.orderFrontRegardless()
    }

    /// The two-row window the transcript scrolls inside.
    static let previewViewport: CGFloat = 28

    /// What the preview adds to the panel: the viewport plus the stack spacing
    /// above it. `HUDModel.preferredHeight` adds exactly this much when there is
    /// text, so the two cannot drift. It is also the click-through strip.
    static let previewHeight: CGFloat = previewViewport + 6

    func update(phase: QuickDictationController.Phase, text: String, live: String = "") {
        model.phase = phase
        model.text = text
        model.live = live
        guard let panel else { return }
        (panel.contentView as? HandleOnlyHostingView<DictationHUDView>)?.passThroughBottom =
            text.isEmpty ? 0 : Self.previewHeight
        // Grow downward from the top edge: resizing around the bottom-left origin
        // makes the panel creep up the screen as the transcript arrives.
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: Self.width, height: model.preferredHeight))
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: top - panel.frame.height))
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Without this the panel is invisible in the only situation it exists for.
        panel.hidesOnDeactivate = false
        // Mouse events are accepted, but only the header consumes them — see
        // `HandleOnlyHostingView`. `.nonactivatingPanel` means even those clicks
        // do not take focus from the app the text is about to be pasted into.
        panel.ignoresMouseEvents = false
        model.mode = insertMode?() ?? .tidiedTranscript
        panel.contentView = HandleOnlyHostingView(rootView: DictationHUDView(
            model: model,
            onDrag: { [weak self] in self?.dragChanged() },
            onDragEnd: { [weak self] in self?.dragEnded() },
            onModeChange: { [weak self] mode in
                self?.model.mode = mode
                self?.onInsertModeChanged?(mode)
            },
            onCancel: { [weak self] in self?.onCancel?() }
        ))
        return panel
    }

    /// Sit where the user last put it; failing that, just below-right of the
    /// pointer. Either way, clamped so the panel never lands partly off-screen.
    private func position(_ panel: NSPanel, near point: NSPoint) {
        let size = panel.frame.size
        var origin = pinnedOrigin ?? NSPoint(x: point.x + 16, y: point.y - size.height - 16)
        // Clamp against the screen the panel would land on, not the one the
        // pointer is on: a remembered position may be on a display that has since
        // been disconnected, and an unclamped origin puts the panel nowhere.
        let screen = NSScreen.screens.first { $0.frame.contains(origin) }
            ?? NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Drag

    /// Move the panel by the **absolute** mouse delta, the way the caption
    /// overlay does. A SwiftUI gesture translation is measured in a coordinate
    /// space that moves with the window, so using it to move that same window
    /// feeds the panel's own motion back into the gesture.
    private func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragMouseStart == nil {
            dragMouseStart = mouse
            dragOriginStart = panel.frame.origin
        }
        guard let startMouse = dragMouseStart, let startOrigin = dragOriginStart else { return }
        panel.setFrameOrigin(NSPoint(
            x: startOrigin.x + (mouse.x - startMouse.x),
            y: startOrigin.y + (mouse.y - startMouse.y)
        ))
    }

    private func dragEnded() {
        dragMouseStart = nil
        dragOriginStart = nil
        guard let panel else { return }
        pinnedOrigin = panel.frame.origin
        onPositionChanged?(panel.frame.origin)
    }
}

/// Click-through over the transcript, interactive over the controls.
///
/// The panel appears 16 pt below-right of the pointer, which is very often
/// exactly where the user is about to click. Same approach as the caption
/// overlay, which is click-through except over its hover control bar.
private final class HandleOnlyHostingView<Content: View>: NSHostingView<Content> {
    /// Height of the click-through strip at the **bottom** of the panel.
    ///
    /// Only the transcript preview passes clicks through: it is the tallest part,
    /// it is pure output, and it is the part most likely to be sitting over
    /// something the user wants to click. Everything above it — ✕, the mode
    /// buttons, any offered action, the drag handle — must stay hittable. It
    /// exists only while there is text, so the owner sets this to match.
    var passThroughBottom: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Bottom-left origin: the transcript is the low-y region.
        guard point.y >= passThroughBottom else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
private final class HUDModel: ObservableObject {
    @Published var phase: QuickDictationController.Phase = .idle
    @Published var text: String = ""
    @Published var mode: PromptQuickInsertMode = .tidiedTranscript
    /// The tail of `text` that is still being revised by the recognizer. Kept
    /// apart from the finalized part for the same reason the caption band keeps
    /// its live line apart: otherwise words still being rewritten look exactly
    /// like committed ones.
    @Published var live: String = ""
    var preferredHeight: CGFloat {
        text.isEmpty ? 78 : 78 + DictationHUDWindow.previewHeight
    }

    /// The whole transcript. **Not sliced.**
    ///
    /// A character budget with a leading ellipsis was the wrong instrument: it has
    /// to guess how many characters a row holds, and when the guess is wrong — or
    /// the rows it was sized for are squeezed by a two-line status label — what is
    /// left is one line and an ellipsis, with the words that followed unreachable.
    /// A two-row viewport that scrolls to the bottom shows the newest words by
    /// construction, whatever the script and whatever the row actually fits.
    var preview: String { text }

    /// `preview` split at the boundary between settled and still-being-revised
    /// text, so the two can be drawn differently.
    var previewCommitted: String {
        let shown = preview
        guard !live.isEmpty, shown.hasSuffix(live) else { return shown }
        return String(shown.dropLast(live.count))
    }

    var previewLive: String {
        let shown = preview
        return (!live.isEmpty && shown.hasSuffix(live)) ? live : ""
    }
}

private struct DictationHUDView: View {
    @ObservedObject var model: HUDModel
    let onDrag: () -> Void
    let onDragEnd: () -> Void
    let onModeChange: (PromptQuickInsertMode) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                indicator
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CaptionTheme.Palette.inkPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // The panel is the only place either key is discoverable: it is on
                // screen while another application has focus, so there is no menu
                // to find them in.
                Text("⌃⌥Space · esc")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                    .help("⌃⌥Space 完成並插入 · esc 取消不插入")
                cancelButton
                dragHandle
            }
            modePicker
            if !model.text.isEmpty {
                // A two-row window onto the whole transcript, held at the bottom.
                //
                // The newest words are the proof that what is being said right now
                // is being heard, so they are what the window has to show — and
                // anchoring the scroll to the bottom does that for any length of
                // dictation, in any script, without guessing how much fits.
                //
                // Two weights of ink and nothing else: settled text in the normal
                // colour, the tail still being revised in the weaker one. An
                // underline reads as an error marker at this size.
                ScrollView(.vertical, showsIndicators: false) {
                    (Text(model.previewCommitted)
                        .foregroundStyle(CaptionTheme.Palette.inkSecondary)
                     + Text(model.previewLive)
                        .foregroundStyle(CaptionTheme.Palette.inkTertiary))
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                // Not the user's to scroll: the preview sits in the panel's
                // click-through strip, and a dictation is watched rather than read
                // back. Following the newest line is the whole job.
                .scrollDisabled(true)
                .frame(height: DictationHUDWindow.previewViewport)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: DictationHUDWindow.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CaptionTheme.Palette.canvas.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CaptionTheme.Palette.inkTertiary.opacity(0.25), lineWidth: 1)
        )
    }

    /// What gets inserted at the cursor. Three buttons rather than a `Picker`,
    /// because a segmented control in a non-activating panel routes its selection
    /// through focus, and this panel deliberately never takes focus.
    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(PromptQuickInsertMode.allCases) { mode in
                let selected = model.mode == mode
                Button { onModeChange(mode) } label: {
                    Text(mode.shortName)
                        .font(.system(size: 10, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected
                            ? CaptionTheme.Palette.inkPrimary : CaptionTheme.Palette.inkTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? CaptionTheme.Palette.privacy.opacity(0.22) : .clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(mode.explanation)
            }
            Spacer(minLength: 0)
        }
    }

    /// Cancel, as a control rather than as a key.
    ///
    /// ⎋ reaches this panel through a global hot key, and a hot key can be refused
    /// when another process already owns the combination. A button on a window
    /// that is already on screen cannot be, whichever display the user is on and
    /// whichever application is frontmost.
    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("取消，不插入任何文字 Cancel without inserting")
        .accessibilityLabel("取消口述 Cancel dictation")
    }

    /// The same 2×3 dot handle the caption band uses, so "this can be moved"
    /// looks the same in both places.
    private var dragHandle: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2) {
                    Circle().fill(CaptionTheme.Palette.inkTertiary).frame(width: 2.5, height: 2.5)
                    Circle().fill(CaptionTheme.Palette.inkTertiary).frame(width: 2.5, height: 2.5)
                }
            }
        }
        .padding(.leading, 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { _ in onDrag() }
                .onEnded { _ in onDragEnd() }
        )
        .help("拖曳移動 Drag to move")
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .listening:
            // The caption band's own dot, not a copy of it. A static dot says
            // "on"; a pulsing one says "hearing you right now", and the panel
            // had the static one. Reusing the type keeps the two surfaces
            // pulsing at the same rate, which is the point of them matching.
            BreathingDot(color: CaptionTheme.Palette.mic, size: 8)
        case .downloading, .warming, .finishing, .preparingModel, .tidying, .compiling:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 8, height: 8)
        case .inserting:
            Image(systemName: "text.cursor").font(.system(size: 10))
                .foregroundStyle(CaptionTheme.Palette.privacy)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var label: String {
        switch model.phase {
        case .idle: return ""
        case let .downloading(fraction): return "下載語音模型 Downloading… \(Int(fraction * 100))%"
        case .warming: return "載入模型 Warming up…"
        case .preparingModel: return "準備語言模型 Preparing model…"
        case .listening: return "聆聽中 Listening…"
        case .finishing: return "收尾中 Finishing…"
        case let .tidying(fraction): return "整理逐字稿 Tidying… \(Int(fraction * 100))%"
        case let .compiling(tokens): return tokens > 0 ? "編譯中 Compiling… \(tokens)" : "編譯中 Compiling…"
        case let .failed(message): return message
        case .inserting: return "插入中 Inserting…"
        }
    }
}
