import Foundation

/// One finalized line of transcript (data-model.md: TranscriptSegment).
public struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sessionId: UUID
    public var index: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var source: AudioSourceType
    public var speakerLabel: String?
    public var sourceText: String
    public var translatedText: String?
    public var isFinalized: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        source: AudioSourceType,
        speakerLabel: String? = nil,
        sourceText: String,
        translatedText: String? = nil,
        isFinalized: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.speakerLabel = speakerLabel
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.isFinalized = isFinalized
        self.createdAt = createdAt
    }
}
