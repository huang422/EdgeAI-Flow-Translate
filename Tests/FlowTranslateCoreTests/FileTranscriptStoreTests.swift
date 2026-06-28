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
}
