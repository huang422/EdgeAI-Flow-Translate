import SwiftUI

@main
struct FlowTranslateApp: App {
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
        }
        // Allow the user to resize the window larger; the transcript list scrolls.
        .windowResizability(.contentMinSize)
    }
}
