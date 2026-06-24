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
}
