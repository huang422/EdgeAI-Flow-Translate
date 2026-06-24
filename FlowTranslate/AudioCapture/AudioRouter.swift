import Foundation
import FlowTranslateCore

/// Multi-source audio routing: aggregates microphone and system-audio capture
/// into one source-tagged stream (contracts/audio-capture.md, T030).
public final class AudioRouter: AudioRouting, @unchecked Sendable {
    public private(set) var activeSources: Set<AudioSourceType> = []
    public var onChunk: ((AudioChunk) -> Void)?

    private var capturers: [AudioSourceType: AudioCapturing] = [:]

    public init() {}

    public func enable(_ source: AudioSourceType) async throws {
        guard !activeSources.contains(source) else { return }

        let capturer: AudioCapturing
        switch source {
        case .microphone:
            capturer = MicCapture()
        case .system:
            if #available(macOS 13.0, *) {
                capturer = SystemAudioTap()
            } else {
                throw AudioCaptureError.systemAudioUnavailable
            }
        }

        capturer.onChunk = { [weak self] chunk in
            self?.onChunk?(chunk)
        }
        try await capturer.start()
        capturers[source] = capturer
        activeSources.insert(source)
    }

    public func disable(_ source: AudioSourceType) {
        capturers[source]?.stop()
        capturers[source] = nil
        activeSources.remove(source)
    }
}
