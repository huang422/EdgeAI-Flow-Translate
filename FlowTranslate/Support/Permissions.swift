import AVFoundation
import AppKit
import FlowTranslateCore
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// Permission queries and requests (microphone / screen recording) (FR-014).
public enum Permissions {

    // MARK: - Microphone

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    @discardableResult
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Open System Settings → Privacy & Security → Microphone.
    public static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Screen Recording (required for system-audio capture)

    /// Whether screen-recording permission has been granted, probed by trying to
    /// fetch shareable content.
    public static func screenRecordingAuthorized() async -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    /// Triggers the system's screen-recording authorization prompt (the first
    /// SCShareableContent call guides the user to System Settings).
    public static func requestScreenRecording() async -> Bool {
        await screenRecordingAuthorized()
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    public static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - TCC reset (stale entries after reinstall)

    /// The TCC privacy services this app uses.
    private static let tccServices = ["Microphone", "ScreenCapture"]

    /// Remove this app's Microphone / Screen Recording privacy entries so the
    /// next launch prompts fresh (`tccutil reset <service> <bundle-id>`).
    ///
    /// Why: macOS keys a TCC grant to the app's code signature. A rebuilt
    /// unsigned/ad-hoc build no longer matches the old entry, so after a
    /// reinstall the Privacy toggle looks ON but the permission silently fails,
    /// and the user has to delete the entry by hand. Resetting at uninstall (and
    /// on demand from Settings) means a fresh install just prompts again.
    /// `tccutil` only deletes entries — it can never grant anything.
    @discardableResult
    public static func resetPrivacyPermissions() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        var allSucceeded = true
        for service in tccServices {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleId]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                allSucceeded = allSucceeded && process.terminationStatus == 0
            } catch {
                allSucceeded = false
            }
        }
        return allSucceeded
    }
}
