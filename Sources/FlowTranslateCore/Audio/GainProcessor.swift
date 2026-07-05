import Foundation
import Accelerate

/// Per-source input-gain configuration.
///
/// Drives an *upward* compressor: it makes **quiet** audio louder so a soft
/// speaker in an online meeting still clears the capture pipeline's level gates
/// (Silero VAD + the `rms ≥ 0.012` voiced check) and reaches the ASR. It never
/// pushes a signal past the limiter ceiling, so it can't introduce clipping.
///
/// Two independent controls:
/// - `manualGainDb` — a fixed, deterministic boost (no adaptation → no pumping).
/// - `autoEnabled`  — additionally raises quiet speech toward `targetDbfs`
///   automatically, but only *upward* from the manual floor, rate-limited and
///   noise-gated so it can never destabilise (worst case: it does nothing).
///
/// Non-user tuning constants default to WebRTC AGC2's proven values.
public struct GainConfig: Sendable, Equatable {
    /// Fixed manual boost in dB, clamped to `0...maxGainDb`. 0 = unity (off).
    public var manualGainDb: Double
    /// Enable adaptive upward gain toward `targetDbfs` on top of the manual floor.
    public var autoEnabled: Bool

    // MARK: Tuning (WebRTC AGC2-derived; not surfaced in the UI)

    /// Loudness the adaptive gain aims quiet speech at (RMS dBFS).
    public var targetDbfs: Double
    /// Hard ceiling on total applied gain (WebRTC `kMaxGainDb` = 30 dB).
    public var maxGainDb: Double
    /// Max gain change per second — the attack/release slew that prevents
    /// "breathing"/pumping (WebRTC `kMaxGainChangePerSecondDb` = 3 dB/s).
    public var maxGainSlewDbPerSec: Double
    /// Chunks quieter than this are treated as noise/silence: the adaptive gain
    /// *holds* instead of ramping up, so background hiss isn't amplified
    /// (WebRTC `kMaxNoiseLevelDbfs` = -50 dBFS).
    public var noiseFloorDbfs: Double
    /// Output peak ceiling for the soft limiter, giving 1 dB of headroom
    /// (WebRTC `kHeadroomDbfs` = 1 dB → -1 dBFS) so boosted peaks never clip.
    public var limiterCeilingDbfs: Double

    public init(
        manualGainDb: Double = 0,
        autoEnabled: Bool = false,
        targetDbfs: Double = -20,
        maxGainDb: Double = 30,
        maxGainSlewDbPerSec: Double = 3,
        noiseFloorDbfs: Double = -50,
        limiterCeilingDbfs: Double = -1
    ) {
        self.maxGainDb = maxGainDb
        self.manualGainDb = min(max(manualGainDb, 0), maxGainDb)
        self.autoEnabled = autoEnabled
        self.targetDbfs = targetDbfs
        self.maxGainSlewDbPerSec = maxGainSlewDbPerSec
        self.noiseFloorDbfs = noiseFloorDbfs
        self.limiterCeilingDbfs = limiterCeilingDbfs
    }

    /// Unity, no adaptation — the signal is forwarded untouched.
    public static let disabled = GainConfig()

    /// When true the processor is a no-op and can be skipped entirely.
    public var isPassthrough: Bool { !autoEnabled && manualGainDb <= 0 }
}

/// Pure, deterministic gain stage: manual/auto upward gain followed by a soft
/// peak limiter. One instance per audio source (it holds the smoothed adaptive
/// gain). Real-time safe — a single vDSP scalar multiply plus a sparse soft-clip
/// pass, O(n) with no allocations on the hot path.
///
/// Concurrency is the caller's responsibility (see `AudioRouter`); the algorithm
/// itself is a plain value type so it stays fully unit-testable, mirroring
/// `AudioMath` / `Endpointer`.
public struct GainProcessor {
    public var config: GainConfig
    /// Smoothed gain currently applied, in dB (the adaptive state).
    private var currentGainDb: Double

    public init(config: GainConfig = .disabled) {
        self.config = config
        self.currentGainDb = config.manualGainDb
    }

    /// The linear gain applied on the most recent `process` (for metering/tests).
    public var appliedLinearGain: Double { pow(10, currentGainDb / 20) }

    /// Amplify `samples` in place. `sampleRate` sizes the per-chunk slew from the
    /// chunk's duration, so the result is deterministic (no wall-clock).
    /// Returns the linear gain actually applied.
    @discardableResult
    public mutating func process(_ samples: inout [Float], sampleRate: Double = 16_000) -> Double {
        let n = samples.count
        guard n > 0 else { return appliedLinearGain }

        let manual = min(max(config.manualGainDb, 0), config.maxGainDb)

        if !config.autoEnabled {
            // Fixed gain: jump straight to it — deterministic, no smoothing.
            currentGainDb = manual
        } else {
            let dt = Double(n) / sampleRate
            let rms = Double(AudioMath.rms(samples))
            let rmsDbfs = rms > 1e-9 ? 20 * log10(rms) : -160

            // Desired gain: lift quiet speech to `targetDbfs`, but only upward from
            // the manual floor. Below the noise floor, hold (don't amplify silence).
            let desired: Double
            if rmsDbfs > config.noiseFloorDbfs {
                desired = min(max(manual, config.targetDbfs - rmsDbfs), config.maxGainDb)
            } else {
                desired = max(manual, currentGainDb)
            }

            // Slew-limit toward the target (symmetric attack/release).
            let maxStep = config.maxGainSlewDbPerSec * dt
            let delta = desired - currentGainDb
            currentGainDb += min(max(delta, -maxStep), maxStep)
            currentGainDb = min(max(currentGainDb, manual), config.maxGainDb)
        }

        let linGain = pow(10, currentGainDb / 20)
        // Unity (or below) → nothing to do and no clipping risk.
        guard linGain > 1.000_000_1 else { return linGain }

        applyGain(Float(linGain), to: &samples)
        softLimit(&samples)
        return linGain
    }

    // MARK: - DSP

    /// SIMD scalar multiply (Accelerate/vDSP → hardware-accelerated on Apple silicon).
    private func applyGain(_ gain: Float, to samples: inout [Float]) {
        var g = gain
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_vsmul(base, 1, &g, base, 1, vDSP_Length(buf.count))
        }
    }

    /// Transparent below a knee just under the ceiling, then compresses peaks so
    /// `|out|` asymptotically approaches — but never exceeds — the ceiling. This
    /// keeps the promised 1 dB headroom and avoids the harmonic distortion of hard
    /// clipping (which degrades ASR accuracy).
    private func softLimit(_ samples: inout [Float]) {
        let ceiling = pow(10, config.limiterCeilingDbfs / 20)   // max |output|, e.g. -1 dBFS → 0.8913
        let knee = ceiling * 0.85                               // transparent below this
        let range = ceiling - knee
        guard range > 0 else { return }
        samples.withUnsafeMutableBufferPointer { buf in
            for i in 0..<buf.count {
                let x = Double(buf[i])
                let a = abs(x)
                guard a > knee else { continue }
                let comp = knee + range * tanh((a - knee) / range)
                buf[i] = Float(x < 0 ? -comp : comp)
            }
        }
    }
}
