import Foundation

/// Audio capture protocol (contracts/audio-capture.md).
public protocol AudioCapturing: AnyObject {
    var source: AudioSourceType { get }
    var isCapturing: Bool { get }
    func start() async throws
    func stop()
    var onChunk: ((AudioChunk) -> Void)? { get set }
}

/// Multi-source audio routing protocol.
public protocol AudioRouting: AnyObject {
    var activeSources: Set<AudioSourceType> { get }
    func enable(_ source: AudioSourceType) async throws
    func disable(_ source: AudioSourceType)
    var onChunk: ((AudioChunk) -> Void)? { get set }
}

/// ASR streaming protocol (contracts/asr.md).
public protocol ASRStreaming: AnyObject {
    func loadModels(tier: String) async throws
    func startStream() async throws
    func feed(_ chunk: AudioChunk)
    func stopStream()
    var onEvent: ((TranscriptEvent) -> Void)? { get set }
}

/// Simplified-to-Traditional Chinese conversion protocol.
public protocol SimplifiedToTraditionalConverting: Sendable {
    func s2twp(_ text: String) -> String
}

/// Pre-finalization text cleanup protocol (contracts/translation.md, FR-006).
public protocol TextCleaning: Sendable {
    func cleanup(_ text: String) -> String
}

/// Transcript storage protocol (contracts/transcript-store.md).
public protocol TranscriptStoring: AnyObject {
    var segments: [TranscriptSegment] { get }
    var onChange: (() -> Void)? { get set }
    func beginSession(settings: CaptionSettings) -> Session
    func append(_ segment: TranscriptSegment)
    func updateTranslation(segmentId: UUID, translated: String)
    func endSession()
}

/// Meeting summarization protocol (contracts/summarization.md, non real-time).
///
/// Produces the summary in **both** English and Traditional Chinese as two
/// separate structured `Summary` values (not one mixed-language summary).
public protocol MeetingSummarizing: AnyObject {
    func summarizeBilingual(
        session: Session,
        segments: [TranscriptSegment],
        progress: ((Double) -> Void)?
    ) async throws -> (english: Summary, chinese: Summary)
}

public extension MeetingSummarizing {
    /// Convenience: the Traditional Chinese summary only.
    func summarize(
        session: Session,
        segments: [TranscriptSegment],
        progress: ((Double) -> Void)?
    ) async throws -> Summary {
        try await summarizeBilingual(session: session, segments: segments, progress: progress).chinese
    }
}

/// Transcript export protocol (contracts/transcript-store.md).
public protocol TranscriptExporting: Sendable {
    func export(
        session: Session,
        segments: [TranscriptSegment],
        summary: Summary?,
        format: ExportFormat
    ) throws -> Data
}
