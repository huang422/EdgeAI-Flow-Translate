import Foundation

/// What the *system audio* actually is, chosen by the user in Settings. Produced
/// content (videos, courses) is edited speech: pauses are short and sit at
/// sentence boundaries, so captions can split quickly. Live human speech
/// (meetings) contains long mid-sentence "thinking" pauses, so splitting needs a
/// longer silence before finalizing or sentences get chopped in half.
public enum CaptureScenario: String, Codable, Sendable, CaseIterable, Identifiable {
    /// System audio is produced/edited content (YouTube, courses, films).
    case video
    /// System audio is live human speech (online meeting, webinar Q&A).
    case meeting

    public var id: String { rawValue }
}

/// Per-source utterance-segmentation timing, derived from the scenario.
///
/// Values are grounded in what streaming-caption products ship:
/// Azure Speech segments at ~500 ms of silence, AssemblyAI defaults to 700 ms and
/// recommends longer for multi-speaker conversation, Deepgram recommends ≥1000 ms
/// for utterance ends, and FluidAudio's own default is 750 ms. Linguistics
/// literature (Goldman-Eisler 1968; Heldner & Edlund 2010) shows read/produced
/// speech pauses are 0.15–0.5 s at syntactic boundaries only, while spontaneous
/// speech hesitates 0.5–1.5 s mid-sentence — hence the two profiles.
public struct SegmentationTuning: Sendable, Equatable {
    /// Trailing silence that ends an utterance (Silero VAD `minSilenceDuration`).
    public let minSilence: TimeInterval
    /// Minimum voiced time before an utterance may finalize (drops blips/coughs).
    public let minSpeech: TimeInterval
    /// Hard cap so a non-stop talker still flushes to ASR/translation.
    public let maxSpeech: TimeInterval

    public init(minSilence: TimeInterval, minSpeech: TimeInterval, maxSpeech: TimeInterval) {
        self.minSilence = minSilence
        self.minSpeech = minSpeech
        self.maxSpeech = maxSpeech
    }

    /// Produced content: fast splits at edited sentence boundaries.
    public static let video = SegmentationTuning(minSilence: 0.30, minSpeech: 0.30, maxSpeech: 8)
    /// Live speech: tolerate mid-sentence thinking pauses; drop short backchannels
    /// ("mm-hm") via the longer minSpeech; allow longer turns before force-flush.
    public static let meeting = SegmentationTuning(minSilence: 0.80, minSpeech: 0.40, maxSpeech: 10)

    public static func forScenario(_ scenario: CaptureScenario) -> SegmentationTuning {
        switch scenario {
        case .video: return .video
        case .meeting: return .meeting
        }
    }

    /// Tuning for one audio source. The scenario describes the *system* audio;
    /// the microphone is always a live human speaking, so it always uses the
    /// meeting profile regardless of scenario.
    public static func forSource(_ source: AudioSourceType, scenario: CaptureScenario) -> SegmentationTuning {
        source == .microphone ? .meeting : forScenario(scenario)
    }
}
