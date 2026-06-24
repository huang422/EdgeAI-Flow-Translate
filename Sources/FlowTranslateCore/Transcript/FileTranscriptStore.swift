import Foundation

/// File-backed transcript store (FR-008): persists the session and its segments
/// to a JSON file so an unexpectedly-closed App does not lose accumulated data.
///
/// Every mutation (append / translation update / end) is written through to disk
/// atomically. On launch the App can call `recoverIncompleteSession()` to detect
/// a session that was never ended (i.e. a crash) and resume or export it.
///
/// This is a dependency-free alternative to SQLite that is fully unit-testable in
/// the pure-Swift core; the platform layer may still swap in GRDB/SQLite later.
public final class FileTranscriptStore: TranscriptStoring {
    /// On-disk snapshot of the current session.
    private struct Snapshot: Codable, Sendable {
        var session: Session
        var segments: [TranscriptSegment]
    }

    private let fileURL: URL
    /// Serial queue so disk writes never block the caller (the main thread).
    private let ioQueue = DispatchQueue(label: "dev.flowtranslate.transcript.io", qos: .utility)
    /// Debounced write so a busy meeting doesn't re-encode + rewrite every sentence.
    private var pendingWrite: DispatchWorkItem?
    private let writeDebounce: TimeInterval = 2.5
    private(set) public var session: Session?
    private var _segments: [TranscriptSegment] = []
    private var indexById: [UUID: Int] = [:]

    public var onChange: (() -> Void)?

    /// - Parameters:
    ///   - directory: directory to store the snapshot in (created if missing).
    ///   - fileName: snapshot file name.
    public init(directory: URL, fileName: String = "current-session.json") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(fileName)
        loadFromDisk()
    }

    public var segments: [TranscriptSegment] { _segments }

    /// Whether a previously-persisted session exists but was never ended (crash).
    public var hasIncompleteSession: Bool {
        guard let session else { return false }
        return session.isActive
    }

    /// Returns the persisted incomplete session (and its segments), if any, for
    /// recovery or export after an unexpected shutdown.
    public func recoverIncompleteSession() -> (session: Session, segments: [TranscriptSegment])? {
        guard let session, session.isActive else { return nil }
        return (session, _segments)
    }

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
        persist()
        onChange?()
        return s
    }

    public func append(_ segment: TranscriptSegment) {
        indexById[segment.id] = _segments.count
        _segments.append(segment)
        scheduleWrite()
        onChange?()
    }

    public func updateTranslation(segmentId: UUID, translated: String) {
        guard let i = indexById[segmentId] else { return }
        _segments[i].translatedText = translated
        scheduleWrite()
        onChange?()
    }

    public func endSession() {
        session?.endedAt = Date()
        flush()   // guarantee the end-of-meeting state is durable on disk
        onChange?()
    }

    /// Coalesce frequent updates into at most one write per `writeDebounce`,
    /// instead of re-encoding the whole transcript on every sentence. Assumes
    /// mutations happen on the main thread (they do, from the capture pipeline).
    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingWrite = nil
            self?.persist()
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDebounce, execute: work)
    }

    /// Flush any pending write and block until it's on disk (durability point).
    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        persist()
        ioQueue.sync {}
    }

    /// Deletes the persisted snapshot and clears in-memory state.
    public func clear() {
        session = nil
        _segments.removeAll()
        indexById.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Disk I/O

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        session = snapshot.session
        _segments = snapshot.segments
        indexById = Dictionary(
            uniqueKeysWithValues: snapshot.segments.enumerated().map { ($1.id, $0) }
        )
    }

    private func persist() {
        guard let session else { return }
        // Snapshot on the caller thread (cheap), then encode + write off-thread
        // so the live caption loop is never blocked by disk I/O.
        let snapshot = Snapshot(session: session, segments: _segments)
        let url = fileURL
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
