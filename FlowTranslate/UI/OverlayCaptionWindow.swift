import SwiftUI
import AppKit

/// Observable content of the floating caption boxes: the recent caption lines
/// (English + translation) and the current interim line, newest at the bottom.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var lines: [CaptionLine] = []   // recent finalized lines (capped)
    @Published var interimEnglish: String = ""
    @Published var interimChinese: String = ""
    @Published var fontSize: Double = 16
    @Published var showSecondLine: Bool = true

    func clear() {
        lines = []
        interimEnglish = ""
        interimChinese = ""
    }
}

/// Two stacked fixed-size floating boxes: the **top** shows the first caption
/// (recognition), the **bottom** shows the second caption (translation). Each box
/// is a small live preview — lines flow top→bottom, newest at the bottom, older
/// ones scroll up and out. The bottom box is hidden when the second caption is off.
struct OverlayCaptionView: View {
    @ObservedObject var model: OverlayModel

    static let boxHeight: CGFloat = 78   // ~3 lines at the default font
    static let spacing: CGFloat = 14     // clearer gap between the two boxes

    var body: some View {
        VStack(spacing: Self.spacing) {
            captionBox(
                texts: model.lines.map(\.english),
                interim: model.interimEnglish,
                bottomID: "BOTTOM_FIRST"
            )
            if model.showSecondLine {
                captionBox(
                    texts: model.lines.compactMap { ($0.chinese?.isEmpty == false) ? $0.chinese : nil },
                    interim: model.interimChinese,
                    bottomID: "BOTTOM_SECOND"
                )
            }
        }
    }

    private func captionBox(texts: [String], interim: String, bottomID: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(texts.enumerated()), id: \.offset) { _, t in
                        textLine(t, interim: false)
                    }
                    if !interim.isEmpty { textLine(interim, interim: true) }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Auto-scroll so the newest line is always visible at the bottom.
            .onChange(of: texts.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: interim) { _, _ in proxy.scrollTo(bottomID, anchor: .bottom) }
        }
        .frame(height: Self.boxHeight)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func textLine(_ text: String, interim: Bool) -> some View {
        Text(text)
            .font(.system(size: model.fontSize, weight: .semibold))
            .foregroundStyle(.white.opacity(interim ? 0.7 : 1.0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
    }
}

/// Manages the floating-caption NSPanel: always on top, joins all spaces
/// (incl. full-screen), and click-through so it never blocks meeting controls.
/// The panel resizes to one or two boxes depending on the second-caption setting.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel?

    private let panelWidth: CGFloat = 720

    private var currentHeight: CGFloat {
        let boxes = model.showSecondLine ? 2 : 1
        return OverlayCaptionView.boxHeight * CGFloat(boxes)
            + OverlayCaptionView.spacing * CGFloat(boxes - 1)
    }

    func show() {
        if panel == nil { panel = makePanel() }
        positionAtBottomCenter()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func setClickThrough(_ enabled: Bool) {
        panel?.ignoresMouseEvents = enabled
    }

    /// Resize/reposition when the second-caption box is shown or hidden.
    func updateLayout() {
        guard panel != nil else { return }
        positionAtBottomCenter()
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: OverlayCaptionView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: currentHeight)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true   // click-through
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        return panel
    }

    /// Centered horizontally, fixed boxes clear of the screen bottom.
    private func positionAtBottomCenter() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = currentHeight
        let x = visible.midX - panelWidth / 2
        let y = visible.minY + 32   // near the bottom edge
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
    }
}
