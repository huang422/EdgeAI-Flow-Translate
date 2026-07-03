import Foundation
import FluidAudio
import FlowTranslateCore

/// Thin wrapper around FluidAudio's CoreML Silero VAD. Buffers audio into the
/// model's 4096-sample (256 ms) frames and forwards each frame through Silero's
/// own streaming state machine (double-threshold hysteresis + min-silence), which
/// emits `speechStart` / `speechEnd`. No aggregation here — the caller consumes the
/// events directly. Runs on the ANE; `nil` on load failure (caller fails loud).
actor SileroEndpointer {
    private let vad: VadManager
    private var segConfig: VadSegmentationConfig
    private var stream: VadStreamState
    private var buffer: [Float] = []
    private static let frame = VadManager.chunkSize   // 4096 samples (256 ms @16k)

    // Diagnostics: surfaced so the pipeline can confirm Silero is actually firing.
    private(set) var lastProbability: Float = 0
    private(set) var inferenceFailures = 0

    /// Loads the VAD model (downloads on first run). `nil` on failure → fail loud.
    /// Enter threshold 0.5, exit 0.35 (0.15 hysteresis); trailing silence comes
    /// from the scenario tuning (video 0.30 s / meeting 0.80 s).
    init?(tuning: SegmentationTuning = .video, progress: ((Double) -> Void)? = nil) async {
        do {
            vad = try await VadManager(
                config: VadConfig(defaultThreshold: 0.5, computeUnits: .cpuAndNeuralEngine),
                progressHandler: progress.map { p in { @Sendable prog in p(prog.fractionCompleted) } })
        } catch {
            return nil
        }
        segConfig = Self.segmentationConfig(for: tuning)
        stream = await vad.makeStreamState()
    }

    private static func segmentationConfig(for tuning: SegmentationTuning) -> VadSegmentationConfig {
        VadSegmentationConfig(
            minSilenceDuration: tuning.minSilence,
            maxSpeechDuration: tuning.maxSpeech,
            negativeThresholdOffset: 0.15)
    }

    /// Swap the segmentation timing (scenario change between meetings).
    func apply(tuning: SegmentationTuning) {
        segConfig = Self.segmentationConfig(for: tuning)
    }

    /// Drop buffered audio + LSTM state between utterances/meetings.
    func reset() async {
        buffer.removeAll(keepingCapacity: true)
        stream = await vad.makeStreamState()
    }

    /// Run the frames contained in `samples` through Silero, returning any
    /// start/end events. Leftover (<4096) is kept so frame boundaries stay continuous.
    /// Inference errors are counted (not swallowed silently) so the caller can warn.
    func events(for samples: [Float]) async -> [VadStreamEvent] {
        buffer.append(contentsOf: samples)
        var out: [VadStreamEvent] = []
        while buffer.count >= Self.frame {
            let chunk = Array(buffer.prefix(Self.frame))
            buffer.removeFirst(Self.frame)
            do {
                let r = try await vad.processStreamingChunk(chunk, state: stream, config: segConfig)
                stream = r.state
                lastProbability = r.probability
                if let e = r.event { out.append(e) }
            } catch {
                inferenceFailures += 1
            }
        }
        return out
    }
}
