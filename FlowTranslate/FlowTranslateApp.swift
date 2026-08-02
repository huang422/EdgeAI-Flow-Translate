import SwiftUI
import AppKit

/// Terminate hook (M1 fix): Cmd+Q / logout / shutdown used to kill the process
/// while up to 2.5 s of debounced transcript writes were still pending, and left
/// the session flagged active. Flush + close the session before dying.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var viewModel: CaptureViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Delegate callbacks arrive on the main thread.
        MainActor.assumeIsolated {
            AppDelegate.viewModel?.prepareForTermination()
        }
        return .terminateNow
    }
}

@main
struct FlowTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// App-level view model — a SINGLE instance for the whole app lifetime. Closing
    /// the window doesn't quit the app (macOS keeps it running), so if the view model
    /// lived on the view, reopening would create a *second* one — a second overlay
    /// panel + a second ⌃⌥C registration → two desynced floating captions. Owning it
    /// here guarantees exactly one overlay and one hotkey set across open/close.
    @StateObject private var vm = CaptureViewModel()

    var body: some Scene {
        WindowGroup("Flow Translate") {
            ContentView(vm: vm)
                .frame(minWidth: 640, minHeight: 560)
                .onAppear { AppDelegate.viewModel = vm }
        }
        // Allow the user to resize the window larger; the transcript list scrolls.
        .windowResizability(.contentMinSize)
    }
}
