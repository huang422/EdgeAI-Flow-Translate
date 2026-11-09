import SwiftUI
import AppKit

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
        WindowGroup(AppEnvironment.isUIFixture ? "Flow Translate · 隔離 UI 測試（快捷鍵停用）" : "Flow Translate") {
            ContentView(vm: vm)
                .onAppear { AppDelegate.viewModel = vm }
        }
        // Allow the user to resize the window larger; the transcript list scrolls.
        .windowResizability(.contentMinSize)
        .defaultSize(width: AppEnvironment.fixtureDimension("Width", fallback: min(1120, (NSScreen.main?.visibleFrame.width ?? 1160) - 40)),
                     height: AppEnvironment.fixtureDimension("Height", fallback: min(820, (NSScreen.main?.visibleFrame.height ?? 900) - 80)))
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("結束 Flow Translate") { AppDelegate.requestTermination() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            if AppEnvironment.isUIFixture {
                CommandMenu("Layout QA") {
                    Button("640 x 520") { resizeFixture(width: 640, height: 520) }
                    Button("940 x 620") { resizeFixture(width: 940, height: 620) }
                    Button("1120 x 820") { resizeFixture(width: 1120, height: 820) }
                    Divider()
                    ForEach(["first-launch", "summary", "prompt-result", "model-prompt", "caption-replay"], id: \.self) { scenario in
                        Button(scenario) {
                            NotificationCenter.default.post(name: AppEnvironment.fixtureNotification, object: scenario)
                        }
                    }
                }
            }
        }
    }

    @MainActor private func resizeFixture(width: CGFloat, height: CGFloat) {
        guard AppEnvironment.isUIFixture, let window = NSApp.mainWindow else { return }
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }
}
