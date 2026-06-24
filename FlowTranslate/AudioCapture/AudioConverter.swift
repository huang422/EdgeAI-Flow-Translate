import AVFoundation
import FlowTranslateCore

/// Converts arbitrary input audio to the 16 kHz mono Float32 the ASR expects
/// (contracts/audio-capture.md, T017).
public final class AudioConverter {
    public static let targetSampleRate: Double = 16_000

    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConverter.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    public init() {}

    /// Convert an input PCM buffer to a 16 kHz mono Float32 sample array.
    public func convertToMono16k(_ inputBuffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = inputBuffer.format

        if converter == nil || lastInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            lastInputFormat = inputFormat
        }
        guard let converter else { return nil }

        // Estimate output capacity from the sample-rate ratio.
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil,
              let channel = outputBuffer.floatChannelData?[0] else {
            return nil
        }
        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}
