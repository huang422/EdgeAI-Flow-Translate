import AVFoundation
import FlowTranslateCore

/// Microphone capture (AVAudioEngine), emitting 16 kHz mono Float32 AudioChunks (T029).
public final class MicCapture: AudioCapturing, @unchecked Sendable {
    public let source: AudioSourceType = .microphone
    public private(set) var isCapturing: Bool = false
    public var onChunk: ((AudioChunk) -> Void)?

    private let engine = AVAudioEngine()
    private let converter = AudioConverter()
    private let startTime = Date()

    public init() {}

    public func start() async throws {
        guard !isCapturing else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw AudioCaptureError.noInputAvailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let samples = self.converter.convertToMono16k(buffer), !samples.isEmpty else { return }
            let chunk = AudioChunk(
                samples: samples,
                source: .microphone,
                timestamp: Date().timeIntervalSince(self.startTime)
            )
            self.onChunk?(chunk)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Don't leave the tap installed on a failed start — a later retry would
            // try to install a second tap on the same bus.
            input.removeTap(onBus: 0)
            throw error
        }
        isCapturing = true
    }

    public func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
    }
}

public enum AudioCaptureError: Error {
    case noInputAvailable
    case permissionDenied
    case systemAudioUnavailable
}
