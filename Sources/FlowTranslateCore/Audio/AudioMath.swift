import Foundation
import Accelerate

/// Pure audio-math utilities used by the capture layer for level metering.
/// Voice-activity detection now lives in the Silero VAD (`SileroEndpointer`) +
/// the pure `Endpointer` state machine, not here.
public enum AudioMath {
    /// Root Mean Square of the samples — used for level metering.
    /// Returns 0 for an empty buffer. vDSP (SIMD) — this runs on the audio
    /// hot path for every chunk of every source.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var out: Float = 0
        vDSP_rmsqv(samples, 1, &out, vDSP_Length(samples.count))
        return out
    }
}
