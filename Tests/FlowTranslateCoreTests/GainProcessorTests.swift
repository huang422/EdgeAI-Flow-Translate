import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct GainProcessorTests {
    /// Peak magnitude of a sample buffer.
    private func peak(_ s: [Float]) -> Float { s.map(abs).max() ?? 0 }

    @Test func disabledIsPassthrough() {
        #expect(GainConfig.disabled.isPassthrough)
        var proc = GainProcessor(config: .disabled)
        var samples: [Float] = [0.1, -0.2, 0.3, -0.05]
        let original = samples
        proc.process(&samples)
        #expect(samples == original)
    }

    @Test func fixedGainScalesQuietSignal() {
        // +6 dB ≈ ×1.995. A quiet signal stays below the limiter knee → clean scale.
        var proc = GainProcessor(config: GainConfig(manualGainDb: 6))
        var samples = [Float](repeating: 0.1, count: 800)
        proc.process(&samples)
        let expected: Float = 0.1 * 1.9953
        #expect(abs(samples[0] - expected) < 1e-3)
    }

    @Test func fixedGainClampedToMax() {
        // Asking beyond the cap is clamped to maxGainDb (30 by default).
        let cfg = GainConfig(manualGainDb: 999)
        #expect(cfg.manualGainDb == 30)
    }

    @Test func limiterKeepsOutputBelowCeiling() {
        // Huge gain on a loud signal must not clip: |out| ≤ -1 dBFS ceiling (0.8913).
        var proc = GainProcessor(config: GainConfig(manualGainDb: 30))
        var samples = [Float](repeating: 0.5, count: 800)
        samples[10] = -0.9
        proc.process(&samples)
        let ceiling: Float = 0.8913
        #expect(peak(samples) <= ceiling + 1e-4)
        #expect(peak(samples) < 1.0)
    }

    @Test func autoLeavesLoudSignalUntouched() {
        // Auto is upward-only: a signal already above target gets ~unity gain.
        var proc = GainProcessor(config: GainConfig(autoEnabled: true))   // ~-10 dBFS input
        var samples = [Float](repeating: 0.316, count: 1600)
        let g = proc.process(&samples)
        #expect(abs(g - 1.0) < 1e-6)
    }

    @Test func autoRampIsSlewLimited() {
        // A quiet (-40 dBFS) source can't jump to full target gain in one chunk:
        // 0.1 s chunk × 3 dB/s ⇒ ≤ 0.3 dB (≈ ×1.035) after the first chunk.
        var proc = GainProcessor(config: GainConfig(autoEnabled: true))
        var samples = [Float](repeating: 0.01, count: 1600)   // 0.1 s @ 16 kHz
        let g = proc.process(&samples)
        #expect(g > 1.0)
        #expect(g <= pow(10.0, 0.3 / 20.0) + 1e-4)
    }

    @Test func autoConvergesTowardTargetOverTime() {
        // Feeding many quiet chunks steadily increases the gain toward the target.
        var proc = GainProcessor(config: GainConfig(autoEnabled: true))
        var last = 1.0
        for _ in 0..<200 {
            var samples = [Float](repeating: 0.01, count: 1600)
            last = proc.process(&samples)
        }
        // -40 dBFS toward -20 dBFS target ⇒ ~+20 dB (×10). Should climb well past +6 dB.
        #expect(last > 2.0)
        #expect(last <= pow(10.0, 30.0 / 20.0) + 1e-3)   // never beyond the 30 dB cap
    }

    @Test func autoHoldsBelowNoiseFloor() {
        // Near-silence (-60 dBFS < -50 dBFS floor) must not be ramped up (no noise pumping).
        var proc = GainProcessor(config: GainConfig(autoEnabled: true))
        var g = 1.0
        for _ in 0..<50 {
            var samples = [Float](repeating: 0.001, count: 1600)
            g = proc.process(&samples)
        }
        #expect(abs(g - 1.0) < 1e-6)
    }
}
