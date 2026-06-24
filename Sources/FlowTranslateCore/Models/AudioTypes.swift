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

    public init(
        text: String,
        source: AudioSourceType,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerLabel: String? = nil
    ) {
        self.text = text
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.speakerLabel = speakerLabel
    }
}

/// ASR streaming event. `interim` drives the live display; `finalized` feeds
/// translation and the transcript store.
public enum TranscriptEvent: Sendable, Equatable {
    case interim(text: String, source: AudioSourceType, at: TimeInterval)
    case finalized(segment: ASRSegment)
}
