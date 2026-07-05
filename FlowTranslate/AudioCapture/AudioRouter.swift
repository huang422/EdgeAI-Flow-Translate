import Foundation
import FlowTranslateCore

/// Multi-source audio routing: aggregates microphone and system-audio capture
/// into one source-tagged stream (contracts/audio-capture.md, T030).
///
/// Each source is boosted by its own `GainProcessor` **before** it reaches the
/// consumer, so a quiet meeting participant clears the downstream level gates
/// (Silero VAD + the `rms ≥ 0.012` voiced check) and still gets recognised.
public final class AudioRouter: AudioRouting, @unchecked Sendable {
    public private(set) var activeSources: Set<AudioSourceType> = []
    public var onChunk: ((AudioChunk) -> Void)?

    private var capturers: [AudioSourceType: AudioCapturing] = [:]

    /// Per-source gain state + its desired config. Guarded by `gainLock` because
    /// capture callbacks (audio threads) and `setGain` (UI thread) both touch it.
    private var processors: [AudioSourceType: GainProcessor] = [:]
    private var configs: [AudioSourceType: GainConfig] = [
        .system: .disabled, .microphone: .disabled
    ]
    private let gainLock = NSLock()

    public init() {}

    /// Update the per-source input gain live (applied on the next chunk).
    public func setGain(system: GainConfig, mic: GainConfig) {
        gainLock.withLock {
            configs[.system] = system
            configs[.microphone] = mic
            processors[.system]?.config = system
            processors[.microphone]?.config = mic
        }
    }

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

        gainLock.withLock {
            processors[source] = GainProcessor(config: configs[source] ?? .disabled)
        }

        capturer.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.onChunk?(self.boost(chunk))
        }
        try await capturer.start()
        capturers[source] = capturer
        activeSources.insert(source)
    }

    public func disable(_ source: AudioSourceType) {
        capturers[source]?.stop()
        capturers[source] = nil
        gainLock.withLock { processors[source] = nil }
        activeSources.remove(source)
    }

    /// Apply the source's gain in place, persisting the processor's adaptive state.
    private func boost(_ chunk: AudioChunk) -> AudioChunk {
        gainLock.lock()
        defer { gainLock.unlock() }
        guard var proc = processors[chunk.source], !proc.config.isPassthrough else {
            return chunk
        }
        var samples = chunk.samples
        proc.process(&samples)
        processors[chunk.source] = proc
        return AudioChunk(samples: samples, source: chunk.source, timestamp: chunk.timestamp)
    }
}
