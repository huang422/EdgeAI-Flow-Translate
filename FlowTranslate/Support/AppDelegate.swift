import AppKit

/// Terminate hook: Cmd+Q / logout / shutdown can arrive with up to 2.5 s of
/// pending transcript checkpoints, and would leave the session flagged
/// active. Flush and close the session before dying.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var viewModel: CaptureViewModel?
    @MainActor private static var isTerminating = false
    @MainActor private static var quitRequestQueued = false

    /// Programmatic Quit may start inside a SwiftUI action on the main queue.
    /// terminateLater enters a nested modal run loop; requesting it from that
    /// queue can prevent the queued MainActor cleanup from ever running. Enter
    /// termination from a run-loop callback after the action has returned.
    @MainActor static func requestTermination() {
        guard !quitRequestQueued, !isTerminating else { return }
        quitRequestQueued = true
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                // Another native Quit may have arrived before this block.
                guard !isTerminating else { return }
                NSApp.terminate(nil)
                if !isTerminating { quitRequestQueued = false }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Delegate callbacks arrive on the main thread.
        // The original request owns the pending cleanup/reply.
        guard !Self.isTerminating else { return .terminateCancel }
        Self.isTerminating = true
        Task { @MainActor in
            await AppDelegate.viewModel?.prepareForTermination()
            Self.isTerminating = false
            Self.quitRequestQueued = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
