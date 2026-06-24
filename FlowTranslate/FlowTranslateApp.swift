import SwiftUI

@main
struct FlowTranslateApp: App {
    var body: some Scene {
        WindowGroup("Flow Translate") {
            ContentView()
                .frame(minWidth: 640, minHeight: 560)
        }
        // Allow the user to resize the window larger; the transcript list scrolls.
        .windowResizability(.contentMinSize)
    }
}
