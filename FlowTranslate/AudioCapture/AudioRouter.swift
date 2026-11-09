import Foundation
import FlowTranslateCore

/// Multi-source audio routing: aggregates microphone and system-audio capture
/// into one source-tagged stream (contracts/audio-capture.md, T030).
///
/// Each source is boosted by its own `GainProcessor` **before** it reaches the
/// consumer, so a quiet meeting participant clears the downstream level gates
/// (Silero VAD + the `rms ≥ 0.012` voiced check) and still gets recognised.
public final class AudioRouter: AudioRouting, @unchecked Sendable {
    private let sourceLock = NSLock()
    private var enabledSources: Set<AudioSourceType> = []
    private var sourceTokens: [AudioSourceType: UUID] = [:]
    public var activeSources: Set<AudioSourceType> { sourceLock.withLock { enabledSources } }
    private let handlerLock = NSLock()
    private var chunkHandler: ((AudioChunk) -> Void)?
    public var onChunk: ((AudioChunk) -> Void)? {
        get { handlerLock.withLock { chunkHandler } }
        set { handlerLock.withLock { chunkHandler = newValue } }
    }
    private let clock = SessionAudioClock()

    public func beginSession() { clock.begin() }


    private var capturers: [AudioSourceType: AudioCapturing] = [:]

    /// Per-source gain state + its desired config. Guarded by `gainLock` because
    /// capture callbacks (audio threads) and `setGain` (UI thread) both touch it.
    private var processors: [AudioSourceType: GainProcessor] = [:]
    private var configs: [AudioSourceType: GainConfig] = [
        .system: .disabled, .microphone: .disabled
    ]
    private let gainLock = NSLock()

    private let capturerFactory: ((AudioSourceType) throws -> AudioCapturing)?

    public init(capturerFactory: ((AudioSourceType) throws -> AudioCapturing)? = nil) {
        self.capturerFactory = capturerFactory
    }

    /// Update the per-source input gain live (applied on the next chunk).
    public func setGain(system: GainConfig, mic: GainConfig) {
        gainLock.withLock {
            configs[.system] = system
            configs[.microphone] = mic
            processors[.system]?.config = system
            processors[.microphone]?.config = mic
        }
    }

    // Claim ownership on the same actor as the UI's permission/reset check.
    // The native start can suspend only after disable can find this claim.
    @MainActor
    public func enable(_ source: AudioSourceType) async throws {
        guard !activeSources.contains(source) else { return }

        let capturer: AudioCapturing
        if let capturerFactory {
            capturer = try capturerFactory(source)
        } else {
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
        }

        let token = UUID()
        let registered = sourceLock.withLock {
            guard capturers[source] == nil else { return false }
            // Publish before awaiting start so disable can cancel a warming mic.
            capturers[source] = capturer
            sourceTokens[source] = token
            return true
        }
        // A pending start is not an active source. Returning success here lets
        // another caller show an enabled switch before capture has even started.
        guard registered else { throw CancellationError() }

        gainLock.withLock {
            processors[source] = GainProcessor(config: configs[source] ?? .disabled)
        }

        capturer.onChunk = { [weak self] chunk in
            guard let self else { return }
            guard self.sourceLock.withLock({ self.sourceTokens[source] == token }) else { return }
            let normalized = AudioChunk(samples: chunk.samples, source: chunk.source,
                                        timestamp: self.clock.relativeTime(for: chunk.timestamp))
            self.onChunk?(self.boost(normalized))
        }
        do {
            try await capturer.start()
            let accepted = sourceLock.withLock {
                guard sourceTokens[source] == token else { return false }
                enabledSources.insert(source)
                return true
            }
            guard accepted else {
                capturer.stop()
                throw CancellationError()
            }
        } catch {
            let ownsSource = sourceLock.withLock {
                guard sourceTokens[source] == token else { return false }
                capturers[source] = nil
                sourceTokens[source] = nil
                enabledSources.remove(source)
                return true
            }
            capturer.stop()
            if ownsSource { gainLock.withLock { processors[source] = nil } }
            throw error
        }
    }

    public func disable(_ source: AudioSourceType) {
        let capturer = sourceLock.withLock {
            let previous = capturers.removeValue(forKey: source)
            sourceTokens[source] = nil
            enabledSources.remove(source)
            return previous
        }
        capturer?.stop()
        gainLock.withLock { processors[source] = nil }
    }

    /// Apply the source's gain in place, persisting the processor's adaptive state.
    /// The lock only guards taking the processor out / putting it back — the DSP
    /// itself runs outside, so the two capture threads (mic + system) never
    /// serialize each other and `setGain` (UI) is never blocked behind DSP.
    /// Per-source callbacks are serial, so checkout/checkin can't interleave for
    /// the same source.
    private func boost(_ chunk: AudioChunk) -> AudioChunk {
        let checkedOut: GainProcessor? = gainLock.withLock {
            guard let p = processors[chunk.source], !p.config.isPassthrough else { return nil }
            return p
        }
        guard var proc = checkedOut else { return chunk }
        var samples = chunk.samples
        proc.process(&samples)
        gainLock.withLock {
            // Don't resurrect a processor that was disabled (or replaced by a
            // fresh enable) while this chunk was being processed.
            guard processors[chunk.source] != nil else { return }
            // Keep the freshest config (setGain may have run mid-processing).
            if let latest = processors[chunk.source]?.config { proc.config = latest }
            processors[chunk.source] = proc
        }
        return AudioChunk(samples: samples, source: chunk.source, timestamp: chunk.timestamp)
    }
}
