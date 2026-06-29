import Testing
@testable import FlowTranslateCore

@Suite struct AudioMathTests {
    @Test func rmsOfEmptyIsZero() {
        #expect(AudioMath.rms([]) == 0)
    }

    @Test func rmsOfConstant() {
        // RMS of [0.5, 0.5, 0.5] == 0.5
        #expect(abs(AudioMath.rms([0.5, 0.5, 0.5]) - 0.5) < 1e-6)
    }
}
