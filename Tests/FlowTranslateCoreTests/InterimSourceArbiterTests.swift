import XCTest
@testable import FlowTranslateCore

final class InterimSourceArbiterTests: XCTestCase {

    func testFirstSourceTakesOwnership() {
        var a = InterimSourceArbiter(holdInterval: 1.0)
        XCTAssertEqual(a.interim(from: .system, at: 0), .system)
        XCTAssertEqual(a.current, .system)
    }

    func testActiveSourceKeepsOwnershipWhileTalking() {
        var a = InterimSourceArbiter(holdInterval: 1.0)
        a.interim(from: .system, at: 0)
        // Mic butts in 0.3s later while system is still active → system keeps it.
        XCTAssertEqual(a.interim(from: .microphone, at: 0.3), .system)
        XCTAssertEqual(a.current, .system)
    }

    func testOtherSourceTakesOverAfterHold() {
        var a = InterimSourceArbiter(holdInterval: 1.0)
        a.interim(from: .system, at: 0)
        // System silent for > 1s → mic takes over.
        XCTAssertEqual(a.interim(from: .microphone, at: 1.5), .microphone)
        XCTAssertEqual(a.current, .microphone)
    }

    func testEndHandsOverToRecentOtherSource() {
        var a = InterimSourceArbiter(holdInterval: 1.0)
        a.interim(from: .system, at: 0)
        a.interim(from: .microphone, at: 0.4)      // suppressed but recorded
        // System finalizes at 0.6 → mic spoke 0.2s ago → hand over.
        XCTAssertEqual(a.end(.system, at: 0.6), .microphone)
    }

    func testEndWithNoRecentOtherGoesIdle() {
        var a = InterimSourceArbiter(holdInterval: 1.0)
        a.interim(from: .system, at: 0)
        XCTAssertNil(a.end(.system, at: 5))
        XCTAssertNil(a.current)
    }

    func testEndOfBackgroundSourceKeepsOwner() {
        var a = InterimSourceArbiter(holdInterval: 1.0)
        a.interim(from: .system, at: 0)
        a.interim(from: .microphone, at: 0.2)
        XCTAssertEqual(a.end(.microphone, at: 0.5), .system)
        XCTAssertEqual(a.current, .system)
    }

    func testFlappingIsDampedByHysteresis() {
        var a = InterimSourceArbiter(holdInterval: 1.0)
        var owner: [AudioSourceType] = []
        // Both sources alternate every 0.2s — the owner must not flip.
        for i in 0..<10 {
            let t = Double(i) * 0.2
            let s: AudioSourceType = i % 2 == 0 ? .system : .microphone
            owner.append(a.interim(from: s, at: t))
        }
        XCTAssertTrue(owner.allSatisfy { $0 == .system })
    }

    func testResetClearsOwnership() {
        var a = InterimSourceArbiter(holdInterval: 1.0)
        a.interim(from: .system, at: 0)
        a.reset()
        XCTAssertNil(a.current)
        XCTAssertEqual(a.interim(from: .microphone, at: 0.1), .microphone)
    }
}
