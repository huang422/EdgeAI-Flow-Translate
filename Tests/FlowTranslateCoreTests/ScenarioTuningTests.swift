import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct ScenarioTuningTests {
    @Test func meetingToleratesLongerPausesThanVideo() {
        // The whole point of the scenario switch: live speech needs a longer
        // trailing silence than edited video before a sentence is finalized.
        #expect(SegmentationTuning.meeting.minSilence > SegmentationTuning.video.minSilence)
        #expect(SegmentationTuning.meeting.minSpeech >= SegmentationTuning.video.minSpeech)
        #expect(SegmentationTuning.meeting.maxSpeech >= SegmentationTuning.video.maxSpeech)
    }

    @Test func scenarioMapsToProfile() {
        #expect(SegmentationTuning.forScenario(.video) == .video)
        #expect(SegmentationTuning.forScenario(.meeting) == .meeting)
    }

    @Test func microphoneAlwaysUsesMeetingProfile() {
        // The mic is always a live human, regardless of what the system audio is.
        #expect(SegmentationTuning.forSource(.microphone, scenario: .video) == .meeting)
        #expect(SegmentationTuning.forSource(.microphone, scenario: .meeting) == .meeting)
        #expect(SegmentationTuning.forSource(.system, scenario: .video) == .video)
        #expect(SegmentationTuning.forSource(.system, scenario: .meeting) == .meeting)
    }

    @Test func settingsDefaultScenarioIsVideoAndDecodesTolerantly() throws {
        #expect(CaptionSettings.default.scenario == .video)
        // Older persisted JSON without the key upgrades to the default.
        let legacy = try JSONDecoder().decode(CaptionSettings.self, from: Data("{}".utf8))
        #expect(legacy.scenario == .video)
        // Round trip keeps a user-selected scenario.
        var s = CaptionSettings.default
        s.scenario = .meeting
        let back = try JSONDecoder().decode(CaptionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.scenario == .meeting)
    }
}
