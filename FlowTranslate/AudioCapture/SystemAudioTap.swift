import AVFoundation
import ScreenCaptureKit
import FlowTranslateCore

/// System-audio capture (ScreenCaptureKit), emitting 16 kHz mono Float32 AudioChunks (T019).
/// System-audio capture requires the "Screen Recording" permission (TCC).
@available(macOS 13.0, *)
public final class SystemAudioTap: NSObject, AudioCapturing, SCStreamOutput, @unchecked Sendable {
    public let source: AudioSourceType = .system
    public private(set) var isCapturing: Bool = false
    public var onChunk: ((AudioChunk) -> Void)?

    private var stream: SCStream?
    private let converter = AudioConverter()
    private let startTime = Date()
    private let sampleQueue = DispatchQueue(label: "dev.flowtranslate.systemaudio")

    public override init() { super.init() }

    public func start() async throws {
        guard !isCapturing else { return }

        // Fetch shareable content; system-audio capture needs a display as the filter source.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw AudioCaptureError.systemAudioUnavailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't capture our own playback (avoid feedback)
        config.sampleRate = 48_000
        config.channelCount = 2
        // Keep video capture minimal (only audio is needed, but SCStream still
        // requires a valid video configuration).
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        isCapturing = true
    }

    public func stop() {
        guard isCapturing else { return }
        let s = stream
        stream = nil
        isCapturing = false
        Task { try? await s?.stopCapture() }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }
        guard let samples = converter.convertToMono16k(pcm), !samples.isEmpty else { return }
        let chunk = AudioChunk(
            samples: samples,
            source: .system,
            timestamp: Date().timeIntervalSince(startTime)
        )
        onChunk?(chunk)
    }

    /// Convert a (audio) CMSampleBuffer to an AVAudioPCMBuffer.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
