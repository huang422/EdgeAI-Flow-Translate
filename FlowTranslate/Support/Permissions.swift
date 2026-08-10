import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import FlowTranslateCore
import os

/// A privacy pane this app can offer to take the user to.
///
/// **Offered, never taken.** Nothing in this app opens System Settings on its
/// own: a missing permission names its pane in a message and puts a button beside
/// it. Pulling System Settings over whatever the user is working in — from a
/// hotkey that asked for text at their cursor — is a hijack.
public enum PermissionPane: Sendable {
    case microphone
    case screenRecording
    case accessibility

    /// One wording everywhere, so the button reads the same on the panel, in the
    /// main window's status line and in Settings.
    public static let buttonTitle = "開啟設定 Open Settings"

    public var title: String {
        switch self {
        case .microphone: return "麥克風 Microphone"
        case .screenRecording: return "螢幕錄製 Screen Recording"
        case .accessibility: return "輔助使用 Accessibility"
        }
    }

    /// What breaks without it, in one line.
    public var purpose: String {
        switch self {
        case .microphone: return "聽你的聲音，字幕與口述都需要。"
        case .screenRecording: return "擷取系統聲音（會議另一端、影片）。"
        case .accessibility: return "把口述結果直接打進游標位置。"
        }
    }

    /// The `tccutil` service name, so a row can tell whether it was just reset.
    public var tccService: String {
        switch self {
        case .microphone: return "Microphone"
        case .screenRecording: return "ScreenCapture"
        case .accessibility: return "Accessibility"
        }
    }

    @MainActor
    public var isGranted: Bool {
        switch self {
        case .microphone: return Permissions.microphoneStatus == .authorized
        case .screenRecording: return Permissions.screenRecordingAuthorized
        case .accessibility: return Permissions.accessibilityAuthorized
        }
    }

    /// Take the user there. False when System Settings refused the URL, which is
    /// the caller's cue to print the path to click by hand.
    ///
    /// Reached only from the two places a blocked action can report itself: the
    /// dictation panel and the main window's status line. The settings readout
    /// never calls it — see `PermissionsIndicator`.
    @discardableResult
    public func open() -> Bool {
        switch self {
        case .microphone: return Permissions.openMicrophoneSettings()
        case .screenRecording: return Permissions.openScreenRecordingSettings()
        case .accessibility: return Permissions.openAccessibilitySettings()
        }
    }
}

/// Permission queries and requests (microphone / screen recording) (FR-014).
public enum Permissions {

    // MARK: - Opening System Settings

    /// Open System Settings at one Privacy & Security pane.
    ///
    /// `com.apple.settings.PrivacySecurity.extension` is what System Settings has
    /// shipped since Ventura replaced System Preferences; the legacy
    /// `com.apple.preference.security` *prefPane* no longer exists and its URL
    /// resolves to nothing. It is still tried second, for macOS 13.
    ///
    /// - Parameter anchor: the pane's own anchor name, e.g. `Privacy_Microphone`.
    /// - Returns: whether System Settings actually opened.
    @discardableResult
    private static func openPrivacySettings(anchor: String) -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return true }
        }
        return false
    }

    // MARK: - Microphone

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    @discardableResult
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Grant state for the microphone, asking **only** when macOS has never been
    /// asked before. One rule for meetings and dictation both.
    ///
    /// What it cannot fix: macOS keys a grant to the app's **code signature**, so
    /// an unsigned or ad-hoc-signed build is a different app to TCC after every
    /// rebuild and the permission genuinely has to be granted again. See
    /// `resetPrivacyPermissions`.
    public static func ensureMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await requestMicrophone()
        default: return false            // denied / restricted: only Settings helps
        }
    }

    /// Open System Settings → Privacy & Security → Microphone.
    @discardableResult
    public static func openMicrophoneSettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    // MARK: - Screen Recording (required for system-audio capture)

    /// Whether screen-recording permission has been granted, **without**
    /// prompting for it.
    ///
    /// `CGPreflightScreenCaptureAccess` rather than an `SCShareableContent`
    /// fetch: the fetch answers the same question but raises the system dialog as
    /// a side effect, which makes it useless as a check.
    public static var screenRecordingAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Whether this launch has already tried (and failed) to get Screen Recording.
    @MainActor public private(set) static var didPromptScreenRecording = false

    /// Probe for Screen Recording, prompting **at most once per launch**.
    ///
    /// ScreenCaptureKit has the same per-process staleness as Accessibility: the
    /// grant is resolved when the process starts, so granting it while the app
    /// runs does not unblock that run. Nothing here can fix that; what it can do
    /// is stop asking a user who has already said yes, and name the relaunch.
    ///
    /// Two calls because they do different things: the preflight answers
    /// **without** prompting, so it runs on every attempt and reports a grant the
    /// moment the process can see one; the request is the prompt, and runs once.
    @MainActor
    public static func requestScreenRecordingOnce() async -> Bool {
        if screenRecordingAuthorized { return true }
        guard !didPromptScreenRecording else { return false }
        didPromptScreenRecording = true
        // Off the MainActor: `CGRequestScreenCaptureAccess` is synchronous and
        // does not return until the user has dealt with the system dialog, which
        // would freeze the window, the level meters and the captions with it.
        return await Task.detached { CGRequestScreenCaptureAccess() }.value
    }

    /// What to tell the user when system audio still cannot start.
    @MainActor
    public static var screenRecordingHint: String {
        didPromptScreenRecording
            ? "Granted but still failing? Relaunch — a grant made while the app is running is "
                + "not visible to it. If a relaunch does not help, use Settings → Reset permissions."
            : "System audio needs Screen Recording: System Settings → Privacy & Security → "
                + "Screen Recording."
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    @discardableResult
    public static func openScreenRecordingSettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    // MARK: - Accessibility (required to type a dictated prompt at the cursor)

    /// Whether this app may synthesize keyboard events into other apps. Needed
    /// only by the ⌃⌥Space dictation hotkey; captions never touch it.
    public static var accessibilityAuthorized: Bool { AXIsProcessTrusted() }

    /// Show the system's Accessibility prompt.
    ///
    /// Prompts unconditionally, including when the permission has already been
    /// granted — which is why only `requestAccessibilityOnce()` may call it.
    @discardableResult
    private static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Whether this launch has already shown the Accessibility prompt.
    @MainActor public private(set) static var didPromptAccessibility = false

    /// Ask for Accessibility **at most once per launch**.
    ///
    /// macOS resolves Accessibility trust per process and caches it: a grant made
    /// while the app is running is usually not visible to it until a relaunch, so
    /// `AXIsProcessTrusted()` keeps answering `false` after the user has said yes.
    /// Prompting again then puts the system dialog on screen for a permission that
    /// is already ticked.
    ///
    /// After the first ask this returns false without prompting, and callers are
    /// expected to point at System Settings and mention the relaunch — the only
    /// thing that unblocks the stale case.
    @MainActor
    @discardableResult
    public static func requestAccessibilityOnce() -> Bool {
        if accessibilityAuthorized { return true }
        guard !didPromptAccessibility else { return false }
        didPromptAccessibility = true
        return requestAccessibility()
    }

    /// What to tell the user when Accessibility is still not granted.
    ///
    /// Different advice before and after the prompt has been shown: the first
    /// time the dialog does the work, and after that the answer is a relaunch,
    /// because a grant the running process cannot see is indistinguishable from
    /// no grant at all.
    @MainActor
    public static var accessibilityHint: String {
        didPromptAccessibility
            ? "Enable Accessibility in System Settings, then relaunch — a grant made while the "
                + "app is running is not visible to it."
            : "Typing at the cursor needs Accessibility: System Settings → Privacy & Security "
                + "→ Accessibility."
    }

    /// Open System Settings → Privacy & Security → Accessibility.
    @discardableResult
    public static func openAccessibilitySettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    // MARK: - TCC reset (stale entries after reinstall)

    /// The TCC privacy services this app uses. Accessibility is included so the
    /// "reset permissions" and uninstall flows do not leave an orphaned grant
    /// behind for a bundle that no longer exists.
    private static let tccServices = ["Microphone", "ScreenCapture", "Accessibility"]

    /// What the dictation hotkey touches: a microphone to hear, and Accessibility
    /// to type the result into another app. Screen Recording is a captions
    /// concern, and resetting it from the Prompt page would take away a permission
    /// that page never asked for.
    ///
    /// The reset exists because TCC keys a grant to the code signature, so an
    /// ad-hoc-signed build is a new app after every rebuild — and the stale
    /// entries left behind do not merely go unused, they answer for the new one:
    /// the system treats the question as already asked and no dialog appears.
    /// That is unrecoverable from System Settings without knowing to delete
    /// several identical-looking rows.
    public static let dictationServices = ["Microphone", "Accessibility"]

    /// What a reset actually did, per service.
    ///
    /// Per-service rather than one `Bool`: `tccutil` fails for reasons that need
    /// completely different responses — the commonest is exit 64, *"No such bundle
    /// identifier"*, meaning LaunchServices cannot resolve this bundle ID at all,
    /// which has nothing to do with privacy and cannot be fixed by re-running the
    /// command by hand.
    public struct ResetReport: Sendable {
        /// Services that were reset.
        public var succeeded: [String] = []
        /// Services that were not, with the reason `tccutil` gave.
        public var failed: [(service: String, reason: String)] = []

        public var isCompleteSuccess: Bool { failed.isEmpty && !succeeded.isEmpty }

        /// One line for the UI, naming what happened rather than grading it.
        public var summary: String {
            if failed.isEmpty {
                return "Reset \(succeeded.joined(separator: ", ")) — relaunch to grant again."
            }
            let names = failed.map(\.service).joined(separator: ", ")
            let done = succeeded.isEmpty ? "" : "Reset \(succeeded.joined(separator: ", ")). "
            return "\(done)\(names) could not be reset: \(failed[0].reason)"
        }
    }

    /// Remove this app's privacy entries so the next launch prompts fresh
    /// (`tccutil reset <service> <bundle-id>`).
    ///
    /// macOS keys a TCC grant to the app's code signature, so a rebuilt
    /// unsigned/ad-hoc build no longer matches the old entry: the Privacy toggle
    /// looks ON but the permission silently fails. Resetting at uninstall and on
    /// demand means a fresh install prompts again. `tccutil` only deletes entries
    /// — it can never grant anything.
    ///
    /// `stderr` is captured rather than discarded: it is the only place the reason
    /// lives, and the reason is the whole value of the report.
    ///
    /// `@MainActor` because a successful reset also clears this launch's prompt
    /// latches — see `forgetPrompt`.
    @MainActor
    @discardableResult
    public static func resetPrivacyPermissions(services: [String]? = nil) -> ResetReport {
        var report = ResetReport()
        guard let bundleId = Bundle.main.bundleIdentifier else {
            report.failed = (services ?? tccServices).map {
                ($0, "the app has no bundle identifier")
            }
            return report
        }
        for service in services ?? tccServices {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleId]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            do {
                try process.run()
                // Read before waiting: a pipe that fills while nobody is draining
                // it blocks the child, and `waitUntilExit` would then never return.
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    report.succeeded.append(service)
                } else {
                    let message = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    report.failed.append(
                        (service, message.isEmpty
                            ? "tccutil exit \(process.terminationStatus)" : message)
                    )
                }
            } catch {
                report.failed.append((service, error.localizedDescription))
            }
        }
        report.succeeded.forEach(forgetPrompt)
        return report
    }

    /// Put this launch's memory of having asked back to "never asked".
    ///
    /// A reset that deletes the TCC entry but leaves `didPrompt…` set makes the
    /// app describe a permission it has just un-asked as one it has already asked
    /// for: `accessibilityHint` and `screenRecordingHint` keep the "granted but
    /// still failing, relaunch" wording when the truth is now that nothing has
    /// been asked at all.
    ///
    /// It does **not** make the three per-process permissions promptable again in
    /// this launch — macOS resolves Accessibility, Screen Recording and Input
    /// Monitoring when the process starts, so only a relaunch can do that. The
    /// microphone is the exception: `AVCaptureDevice` re-reads TCC, so it really
    /// does prompt again straight away.
    @MainActor
    private static func forgetPrompt(for service: String) {
        switch service {
        case "ScreenCapture": didPromptScreenRecording = false
        case "Accessibility":
            didPromptAccessibility = false
        default: break            // Microphone keeps no latch of its own
        }
        resetServices.insert(service)
    }

    /// Services reset during this launch, so the UI can say "relaunch to grant"
    /// instead of reporting a grant state the process cannot re-read.
    @MainActor public static var resetServices: Set<String> = []
}
