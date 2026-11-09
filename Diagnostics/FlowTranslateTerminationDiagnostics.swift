import AppKit

/// Test dependency for the real AppDelegate in this separate CLI target.
/// No capture, models, production preferences, or transcript files are opened.
@MainActor final class CaptureViewModel {
    private(set) var calls = 0
    private(set) var completed = false
    var requests = 0
    var duringPreparation: (@MainActor @Sendable () -> Void)?
    func prepareForTermination() async {
        calls += 1
        let pending = duringPreparation
        duringPreparation = nil
        pending?()
        try? await Task.sleep(for: .milliseconds(100))
        completed = true
    }
}

private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@main struct FlowTranslateTerminationDiagnostics {
    static func log(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }

    @MainActor static func main() {
        // Independent of the main queue: the old nested-loop deadlock prevents
        // a main-queue timeout from firing too.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            log("FAIL: termination did not complete")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        let vm = CaptureViewModel()
        let external = CommandLine.arguments.contains("--external")
        let repeated = CommandLine.arguments.contains("--repeat")
        if external && (repeated || CommandLine.arguments.contains("--sheet")) {
            log("External entry check is one non-modal Quit; repeated app actions must use requestTermination")
            exit(2)
        }
        AppDelegate.viewModel = vm
        app.delegate = delegate
        let parent = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 520),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: 560, height: 480),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        if CommandLine.arguments.contains("--sheet") { parent.beginSheet(sheet) }
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: app, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard vm.completed, vm.calls == 1, vm.requests == (repeated ? 2 : 1),
                      app.windows.allSatisfy({ $0.attachedSheet == nil }) else {
                    log("FAIL: completed=\(vm.completed) cleanups=\(vm.calls) requests=\(vm.requests) sheets=\(app.windows.filter { $0.attachedSheet != nil }.count)")
                    exit(1)
                }
                log("PASS: main-queue Quit closes sheets and awaits exactly one cleanup")
            }
        }
        let request: @MainActor @Sendable () -> Void = {
            vm.requests += 1
            if external {
                // Simulate AppKit's native event/run-loop entry without using
                // our programmatic helper; do not log out the user's Mac.
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { app.terminate(nil) }
                }
            } else {
                AppDelegate.requestTermination()
            }
        }
        // Trigger the second request from the suspended cleanup itself: timer
        // delivery is mode-dependent inside AppKit's modal termination loop.
        if repeated { vm.duringPreparation = request }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { request() }
        withExtendedLifetime((delegate, vm, parent, sheet, observer)) { app.run() }
        log("FAIL: app run loop returned without termination")
        exit(1)
    }
}
