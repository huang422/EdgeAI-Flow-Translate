import AppKit
import SwiftUI

/// Live state of every privacy permission the app uses.
///
/// At the foot of **both** settings panes, identical in each: a permission is not
/// a captions concern or a prompt concern, it is an app concern, and a user
/// hunting for "why is this not working" should not have to guess which tab keeps
/// the answer.
///
/// **A readout, not a control panel.** Nothing here asks for anything. macOS is
/// asked at the moment the feature that needs it is switched on — the microphone
/// when a source is enabled, Screen Recording when system audio is, Accessibility
/// when the dictation hotkey is switched on — because that is the only moment
/// the request has a reason the user can recognise. A row of buttons that prompt
/// out of context is the same interruption as opening System Settings uninvited,
/// one press further away.
struct PermissionsIndicator: View {
    /// Re-read on a timer as well as on activation.
    ///
    /// The microphone answers from TCC on every call, so it changes under the
    /// sheet while the user is in System Settings. Polling is affordable here in a
    /// way it would not be in a caption view: three cheap calls, only while a
    /// settings sheet is open, and the alternative is a panel that silently
    /// describes the state it had when it opened.
    private static let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let panes: [PermissionPane] =
        [.microphone, .screenRecording, .accessibility]

    @State private var granted: [String: Bool] = [:]
    @State private var resetThisLaunch: Set<String> = []

    var body: some View {
        Section("權限 Permissions") {
            ForEach(Self.panes, id: \.tccService) { pane in
                row(pane)
            }
            Text("需要時會自動詢問你 —— 開啟麥克風或系統音訊、或打開口述快捷鍵開關時。"
                + "除了麥克風之外，授權後都要重新啟動 App 才會生效：macOS 在程式啟動時就決定了這些權限。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: reload)
        .onReceive(Self.refresh) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func row(_ pane: PermissionPane) -> some View {
        let isGranted = granted[pane.tccService] ?? false
        let wasReset = resetThisLaunch.contains(pane.tccService)
        // A reset removes the entry, so a "granted" answer from a process that
        // resolved it at launch is stale — the reset wins until the next launch.
        let state: RowState = wasReset ? .reset : (isGranted ? .granted : .missing)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: state.icon)
                    .foregroundStyle(state.tint)
                    .accessibilityHidden(true)
                Text(pane.title)
                Spacer(minLength: 8)
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(state.tint)
            }
            Text(state == .reset
                 ? "已重設 —— 重新啟動後，下次用到時會再問你一次。\(pane.purpose)"
                 : pane.purpose)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pane.title) \(state.label)")
    }

    private func reload() {
        var next: [String: Bool] = [:]
        for pane in Self.panes { next[pane.tccService] = pane.isGranted }
        granted = next
        resetThisLaunch = Permissions.resetServices
    }

    private enum RowState {
        case granted, missing, reset

        var icon: String {
            switch self {
            case .granted: return "checkmark.circle.fill"
            case .missing: return "exclamationmark.triangle.fill"
            case .reset: return "arrow.clockwise.circle.fill"
            }
        }

        var label: String {
            switch self {
            case .granted: return "已授權"
            case .missing: return "未授權"
            case .reset: return "已重設"
            }
        }

        var tint: Color {
            switch self {
            case .granted: return CaptionTheme.Palette.mic
            case .missing: return .orange
            case .reset: return CaptionTheme.Palette.privacy
            }
        }
    }
}
