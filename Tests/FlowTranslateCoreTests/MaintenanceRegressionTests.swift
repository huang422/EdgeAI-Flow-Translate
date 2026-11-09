import Foundation
import Testing
@testable import FlowTranslateCore

@Suite("Maintenance regressions")
struct MaintenanceRegressionTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellingAWaitDoesNotJoinOrCancelSharedNativeWork() async {
        let gate = SuspendedNativeWork()
        let shared = Task { await gate.run(); return 42 }
        let waiter = Task { await CancellableTaskWait.wait(for: shared) }
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(await gate.isReleased == false)
        #expect(!shared.isCancelled)
        await gate.release()
        #expect(await shared.value == 42)
        #expect(await CancellableTaskWait.wait(for: shared))
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineReturnsWhileNativeWorkIgnoresCancellation() async {
        let gate = SuspendedNativeWork()
        let shared = Task { await gate.run() }
        #expect(await CancellableTaskWait.wait(for: shared, timeout: .milliseconds(30)) == false)
        #expect(await gate.isReleased == false)
        await gate.release()
        await shared.value
    }
    @Test(arguments: ["Chinese", "English spacing", "Identifiers"])
    func longSingleLinePreservesEveryCharacter(_ name: String) {
        let text: String
        switch name {
        case "Chinese": text = String(repeating: "這是一個句子。下一個句子。", count: 90)
        case "English spacing": text = "  " + String(repeating: "First sentence.  Next sentence.\t", count: 120) + "  "
        default: text = String(repeating: "Keep Sources/Uploader.swift and v1.3.0.\t\t", count: 100)
        }
        let chunks = PassageChunker.chunks(text)
        #expect(chunks.count > 1)
        #expect(PassageChunker.rejoin(chunks.map(\.text), chunks: chunks) == text)
    }

    @Test @MainActor
    func continuousUpdatesStillCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowtranslate-checkpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileTranscriptStore(directory: directory)
        let session = store.beginSession(settings: .default)
        store.flush()
        let deadline = ContinuousClock.now + .seconds(4)
        var durable = false
        var index = 0
        while ContinuousClock.now < deadline {
            store.append(TranscriptSegment(
                sessionId: session.id, index: index,
                startTime: Double(index), endTime: Double(index + 1),
                source: .system, sourceText: "checkpoint \(index)"))
            index += 1
            try await Task.sleep(for: .milliseconds(40))
            if try !FileTranscriptStore(directory: directory).segments.isEmpty {
                durable = true
                break
            }
        }
        store.clear()
        #expect(durable, "Continuous activity must not postpone every checkpoint")
    }

    @Test func sourcesShareOneTimelineAndNewMeetingsResetIt() {
        let clock = SessionAudioClock(origin: 100)
        #expect(clock.relativeTime(for: 110) == 10)
        // A second source enabled later uses the same origin.
        #expect(clock.relativeTime(for: 145) == 45)
        clock.begin(at: 200)
        #expect(clock.relativeTime(for: 205) == 5)
        #expect(clock.relativeTime(for: 199) == 0)
    }

    @Test @MainActor func drainIncludesLateFinalEventAndPreservesOrder() async throws {
        let delivery = TranscriptEventDelivery()
        var received: [String] = []
        let producer = Task {
            // The old 600 ms window would end before this finalization.
            try await Task.sleep(for: .milliseconds(750))
            for text in ["first", "last"] {
                delivery.send(.finalized(segment: ASRSegment(
                    text: text, source: .microphone, startTime: 0, endTime: 1))) { event in
                    if case .finalized(let segment) = event { received.append(segment.text) }
                }
            }
        }
        try await producer.value
        await delivery.drain()
        #expect(received == ["first", "last"])
    }

    @Test func existingSettingsUpgradeWithoutMutingTheMicrophone() throws {
        let settings = try JSONDecoder().decode(CaptionSettings.self, from: Data("{}".utf8))
        #expect(!settings.suppressMicDuringSystemAudio)
        var enabled = settings
        enabled.suppressMicDuringSystemAudio = true
        let reopened = try JSONDecoder().decode(CaptionSettings.self, from: JSONEncoder().encode(enabled))
        #expect(reopened.suppressMicDuringSystemAudio)
    }

    @Test func dictationFiltersSystemAudioAndRestoresExistingSource() async throws {
        let router = FakeAudioRouter()
        try await router.enable(.system)
        try await router.enable(.microphone)
        var original: [AudioSourceType] = []
        router.onChunk = { original.append($0.source) }
        var dictated: [AudioSourceType] = []
        let lease = MicrophoneRoutingLease(router: router) { dictated.append($0.source) }
        let borrowedHandler = router.onChunk
        for source in [AudioSourceType.system, .microphone] {
            router.onChunk?(AudioChunk(samples: [0], source: source, timestamp: 1))
        }
        #expect(dictated == [.microphone])
        lease.closeInput()
        lease.closeInput()
        #expect(router.activeSources == [.microphone, .system])
        borrowedHandler?(AudioChunk(samples: [0], source: .microphone, timestamp: 2))
        #expect(dictated.count == 1)
        router.onChunk?(AudioChunk(samples: [0], source: .system, timestamp: 2))
        #expect(original == [.system])
    }

    @Test func dictationClosesOnlyMicrophoneItEnabled() async throws {
        let router = FakeAudioRouter()
        try await router.enable(.system)
        let lease = MicrophoneRoutingLease(router: router) { _ in }
        try await router.enable(.microphone)
        lease.closeInput()
        #expect(router.activeSources == [.system])
    }

    @Test func cancellationBeforeMicrophoneEnableCannotReopenIt() async throws {
        let router = FakeAudioRouter()
        let lease = MicrophoneRoutingLease(router: router) { _ in }
        lease.closeInput()
        do {
            try await lease.enableMicrophone()
            Issue.record("A closed lease must not enable capture")
        } catch is CancellationError {}
        #expect(router.activeSources.isEmpty)
    }

    @Test func cancellationAcrossMicrophoneEnableClosesTheNewSource() async throws {
        let router = FakeAudioRouter()
        router.enableDelay = .milliseconds(80)
        let lease = MicrophoneRoutingLease(router: router) { _ in }
        let start = Task { try await lease.enableMicrophone() }
        try await Task.sleep(for: .milliseconds(20))
        lease.closeInput()
        do {
            try await start.value
            Issue.record("Cancelled capture startup must report cancellation")
        } catch is CancellationError {}
        #expect(router.activeSources.isEmpty)
    }

    @Test @MainActor func quitWaitsForAnAlreadyRunningStop() async throws {
        let stop = MeetingStopCoordinator()
        var finalized = false
        var executions = 0
        let first = Task { @MainActor in
            await stop.run {
                executions += 1
                try? await Task.sleep(for: .milliseconds(750))
                finalized = true
            }
        }
        while !stop.isRunning { await Task.yield() }
        await stop.run { Issue.record("A second caller must share the existing stop") }
        #expect(finalized)
        #expect(executions == 1)
        await first.value
    }
}

private actor SuspendedNativeWork {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isReleased: Bool { released }
    func run() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class FakeAudioRouter: AudioRouting {
    var enableDelay: Duration?
    var activeSources: Set<AudioSourceType> = []
    var onChunk: ((AudioChunk) -> Void)?
    func enable(_ source: AudioSourceType) async throws {
        if let enableDelay { try await Task.sleep(for: enableDelay) }
        activeSources.insert(source)
    }
    func disable(_ source: AudioSourceType) { activeSources.remove(source) }
}
