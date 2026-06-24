import Foundation

/// Pure audio-math utilities shared by the capture layer (level meters),
/// the ASR energy-based VAD, and tests — so the same logic is not duplicated
/// across App layers (CaptureViewModel / NemotronStreamingService).
public enum AudioMath {
    /// Root Mean Square of the samples — used for level metering and energy VAD.
    /// Returns 0 for an empty buffer.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Energy-based voice activity detection: whether RMS reaches the threshold
    /// (default 0.012). Used to filter silence/noise so no garbage captions are
    /// emitted when nobody is speaking (FR-016).
    public static func isVoiced(_ samples: [Float], threshold: Float = 0.012) -> Bool {
        rms(samples) >= threshold
    }
}
