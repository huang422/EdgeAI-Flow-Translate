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

/// How readily the diarizer treats two segments as different people.
///
/// One value cannot serve every room, which is why this is a setting rather than
/// a constant. The dial is a cosine distance between voice embeddings: below it
/// a segment joins the nearest known speaker, above it a new speaker is created.
///
/// - Two people on one microphone sit far apart in embedding space, and the risk
///   is *over*-segmentation — the same voice picked up at two distances, or
///   across a cough, drifting past the threshold and becoming a second person.
///   A loose threshold is right.
/// - Five people on a conference call are compressed by the codec and recorded
///   through one channel, so their embeddings crowd together and the risk is
///   *under*-segmentation — everyone collapsing into two or three speakers. A
///   tight threshold is right.
///
/// Those are opposite corrections, which is why a single default produced both
/// of the complaints this exists to answer.
public enum DiarizationSensitivity: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Fewest speakers. Merges readily — pick it when a two-person conversation
    /// is being reported as four.
    case merge
    /// The default.
    case balanced
    /// Most speakers. Separates readily — pick it when five people are collapsing
    /// into two.
    case split

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .merge: return "偏合併 Fewer speakers"
        case .balanced: return "標準 Balanced"
        case .split: return "偏分離 More speakers"
        }
    }

    public var explanation: String {
        switch self {
        case .merge:
            return "同一個人被拆成好幾個講者時選這個。兩人對談用這個通常最準。"
        case .balanced:
            return "多數會議的預設值。"
        case .split:
            return "人數多卻被合併成兩三個講者時選這個。五人以上的線上會議用這個較準。"
        }
    }

    /// The cosine-distance threshold handed to the clustering config.
    ///
    /// FluidAudio derives the speaker-assignment threshold as `× 1.2` and the
    /// embedding-update threshold as `× 0.8`, so `balanced` lands on 0.66 / 0.44
    /// — the values `SpeakerManager` documents as its own defaults. The previous
    /// setting of 0.7 produced 0.84, a *29% looser* assignment threshold than the
    /// library recommends, which is what let five distinct voices collapse into
    /// two or three.
    public var clusteringThreshold: Float {
        switch self {
        case .merge: return 0.68
        case .balanced: return 0.55
        case .split: return 0.46
        }
    }
}
