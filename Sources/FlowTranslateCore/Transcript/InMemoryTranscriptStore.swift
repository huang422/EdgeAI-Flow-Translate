import Foundation

/// In-memory transcript store (contracts/transcript-store.md).
/// The platform App layer can add SQLite/file persistence on top (see FileTranscriptStore).
public final class InMemoryTranscriptStore: TranscriptStoring {
    private(set) public var session: Session?
    private var _segments: [TranscriptSegment] = []
    private var indexById: [UUID: Int] = [:]

    public var onChange: (() -> Void)?

    public init() {}

    public var segments: [TranscriptSegment] { _segments }

    @discardableResult
    public func beginSession(settings: CaptionSettings) -> Session {
        let s = Session(
            firstLanguage: settings.firstLanguage,
            secondLanguage: settings.secondCaptionEnabled ? settings.secondLanguage.rawValue : "",
            asrTier: settings.asrTier,
            diarizationEnabled: settings.diarizationEnabled
        )
        session = s
        _segments.removeAll()
        indexById.removeAll()
        onChange?()
        return s
    }

    public func append(_ segment: TranscriptSegment) {
        indexById[segment.id] = _segments.count
        _segments.append(segment)
        onChange?()
    }

    public func updateTranslation(segmentId: UUID, translated: String) {
        guard let i = indexById[segmentId] else { return }
        _segments[i].translatedText = translated
        onChange?()
    }

    public func endSession() {
        session?.endedAt = Date()
        onChange?()
    }
}
