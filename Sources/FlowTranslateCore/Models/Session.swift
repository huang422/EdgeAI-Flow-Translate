import Foundation

/// A single meeting record (data-model.md: Session).
public struct Session: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String?
    public var firstLanguage: String
    public var secondLanguage: String
    public var asrTier: String
    public var diarizationEnabled: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        title: String? = nil,
        firstLanguage: String = "en",
        secondLanguage: String = "zh-Hant",
        asrTier: String = "1120ms",
        diarizationEnabled: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.firstLanguage = firstLanguage
        self.secondLanguage = secondLanguage
        self.asrTier = asrTier
        self.diarizationEnabled = diarizationEnabled
    }

    /// Whether the meeting is still in progress (not yet ended).
    public var isActive: Bool { endedAt == nil }
}
