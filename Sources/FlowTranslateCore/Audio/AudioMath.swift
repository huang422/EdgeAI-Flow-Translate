import Foundation

/// Pure audio-math utilities used by the capture layer for level metering.
/// Voice-activity detection now lives in the Silero VAD (`SileroEndpointer`) +
/// the pure `Endpointer` state machine, not here.
public enum AudioMath {
    /// Root Mean Square of the samples — used for level metering.
    /// Returns 0 for an empty buffer.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
