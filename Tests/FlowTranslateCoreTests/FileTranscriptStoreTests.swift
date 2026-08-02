import Testing
import Foundation
@testable import FlowTranslateCore

@Suite struct FileTranscriptStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flowtranslate-tests-\(UUID().uuidString)")
    }

    private func segment(_ session: Session, _ index: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(
            sessionId: session.id, index: index,
            startTime: TimeInterval(index), endTime: TimeInterval(index) + 1,
            source: .system, sourceText: text
        )
    }

    @Test func persistsAndReloads() throws {
        let dir = tempDir()
        let store = try FileTranscriptStore(directory: dir)
        let session = store.beginSession(settings: .default)
        store.append(segment(session, 0, "hello"))
        store.append(segment(session, 1, "world"))
        store.flush()

        // A fresh store over the same directory reloads the persisted data.
        let reopened = try FileTranscriptStore(directory: dir)
        #expect(reopened.segments.count == 2)
        #expect(reopened.segments.first?.sourceText == "hello")
        reopened.clear()
    }

    @Test func updateTranslationPersists() throws {
        let dir = tempDir()
        let store = try FileTranscriptStore(directory: dir)
        let session = store.beginSession(settings: .default)
        let seg = segment(session, 0, "hello")
        store.append(seg)
        store.updateTranslation(segmentId: seg.id, translated: "你好")
        store.flush()

        let reopened = try FileTranscriptStore(directory: dir)
        #expect(reopened.segments.first?.translatedText == "你好")
        reopened.clear()
    }

    @Test func updateSourceTextPersists() throws {
        // A repair that only lived in memory would be lost by the crash-recovery
        // path — the corrected transcript has to be the durable one.
        let dir = tempDir()
        let store = try FileTranscriptStore(directory: dir)
        let session = store.beginSession(settings: .default)
        let seg = segment(session, 0, "we run it on cooper netties")
        store.append(seg)
        store.updateSourceText(segmentId: seg.id, corrected: "we run it on Kubernetes")
        store.flush()

        let reopened = try FileTranscriptStore(directory: dir)
        #expect(reopened.segments.first?.sourceText == "we run it on Kubernetes")
        reopened.clear()
    }

    @Test func recoversIncompleteSessionAfterCrash() throws {
        let dir = tempDir()
        let store = try FileTranscriptStore(directory: dir)
        let session = store.beginSession(settings: .default)
        store.append(segment(session, 0, "interrupted"))
        store.flush()
        // Simulate a crash: process dies without calling endSession().

        let reopened = try FileTranscriptStore(directory: dir)
        #expect(reopened.hasIncompleteSession == true)
        let recovered = reopened.recoverIncompleteSession()
        #expect(recovered?.segments.count == 1)
        reopened.clear()
    }

    @Test func endedSessionIsNotFlaggedIncomplete() throws {
        let dir = tempDir()
        let store = try FileTranscriptStore(directory: dir)
        _ = store.beginSession(settings: .default)
        store.endSession()

        let reopened = try FileTranscriptStore(directory: dir)
        #expect(reopened.hasIncompleteSession == false)
        #expect(reopened.recoverIncompleteSession() == nil)
        reopened.clear()
    }

    /// Regression (H1): starting a NEW session must never overwrite a crashed
    /// session's snapshot — it is archived to a `recovered-*.json` instead.
    @Test func beginSessionArchivesCrashedSnapshotInsteadOfOverwriting() throws {
        let dir = tempDir()
        let store = try FileTranscriptStore(directory: dir)
        let session = store.beginSession(settings: .default)
        store.append(segment(session, 0, "precious words"))
        store.flush()
        // Simulate a crash + relaunch: reload from disk, session still active.
        let reopened = try FileTranscriptStore(directory: dir)
        #expect(reopened.hasIncompleteSession == true)

        // User presses Start → new session begins.
        _ = reopened.beginSession(settings: .default)
        reopened.flush()

        // The crashed transcript survives as an archive file.
        let archives = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("recovered-") && $0.hasSuffix(".json") }
        #expect(archives.count == 1)
        // And the archived file still contains the old segment.
        let data = try Data(contentsOf: dir.appendingPathComponent(archives[0]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("precious words"))
        // The live store starts clean.
        #expect(reopened.segments.isEmpty)
        reopened.clear()
        try? FileManager.default.removeItem(at: dir)
    }

    /// An ended (properly closed) session is NOT archived on the next begin.
    @Test func beginSessionDoesNotArchiveEndedSession() throws {
        let dir = tempDir()
        let store = try FileTranscriptStore(directory: dir)
        let session = store.beginSession(settings: .default)
        store.append(segment(session, 0, "done"))
        store.endSession()

        _ = store.beginSession(settings: .default)
        store.flush()
        let archives = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("recovered-") }
        #expect(archives.isEmpty)
        store.clear()
        try? FileManager.default.removeItem(at: dir)
    }
}
