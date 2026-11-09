import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct SpeakerFinalizationQueueTests {
    @Test func slowSpeakerAnalysisDoesNotBlockInputOrLoseFinalText() async {
        let queue = SpeakerFinalizationQueue(capacity: 2)
        let release = DispatchSemaphore(value: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let delivered = SpeakerResults()
        let segment: (String) -> ASRSegment = {
            ASRSegment(text: $0, source: .system, startTime: 0, endTime: 1)
        }
        let first = segment("First")
        queue.submit(fallback: first, analyze: {
            signal.yield()
            release.wait()
            var obsolete = first
            obsolete.speakerLabel = "Late"
            return [obsolete]
        }, deliver: delivered.append)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()

        let second = segment("Second")
        let third = segment("Third")
        queue.submit(fallback: second, analyze: { [second] }, deliver: delivered.append)
        queue.submit(fallback: third, analyze: { [third] }, deliver: delivered.append)
        #expect(delivered.segments == [first, second])
        release.signal()
        await queue.drain()
        #expect(delivered.segments == [first, second, third])
    }
}

private final class SpeakerResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ASRSegment] = []

    var segments: [ASRSegment] { lock.withLock { values } }
    func append(_ segments: [ASRSegment]) { lock.withLock { values.append(contentsOf: segments) } }
}
