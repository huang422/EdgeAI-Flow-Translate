import Foundation

/// Unified audio chunk emitted by the capture layer (contracts/audio-capture.md).
/// Already converted to 16 kHz mono Float32.
public struct AudioChunk: Sendable, Equatable {
    public let samples: [Float]
    public let source: AudioSourceType
    public let timestamp: TimeInterval

    public init(samples: [Float], source: AudioSourceType, timestamp: TimeInterval) {
        self.samples = samples
        self.source = source
        self.timestamp = timestamp
    }
}

/// One finalized segment from the ASR stream (contracts/asr.md).
public struct ASRSegment: Sendable, Equatable {
    public let text: String
    public let source: AudioSourceType
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public var speakerLabel: String?
    /// The decoder can produce several speaker groups for the same utterance.
    /// Individual word times can end before the partial's trailing silence.
    public let utteranceEndTime: TimeInterval
    public let position: Position
    /// Shared by live text and every diarized group from this decoder segment.
    public let utteranceId: UUID?

    public enum Position: Sendable, Equatable {
        case whole, earlierGroup, lastGroup
    }

    public init(
        text: String,
        source: AudioSourceType,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerLabel: String? = nil,
        utteranceEndTime: TimeInterval? = nil,
        position: Position = .whole,
        utteranceId: UUID? = nil
    ) {
        self.text = text
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.speakerLabel = speakerLabel
        self.utteranceEndTime = utteranceEndTime ?? endTime
        self.position = position
        self.utteranceId = utteranceId
    }
}

/// ASR streaming event. `interim` drives the live display; `finalized` feeds
/// translation and the transcript store.
public enum TranscriptEvent: Sendable, Equatable {
    case interim(text: String, source: AudioSourceType, at: TimeInterval, utteranceId: UUID? = nil)
    /// Decoder text is ready to display while the speaker worker is still busy.
    case previewFinal(ASRSegment)
    case finalized(segment: ASRSegment)
    /// All speaker groups in one delivery so the UI can switch rows together.
    case finalizedGroups([ASRSegment])
}
