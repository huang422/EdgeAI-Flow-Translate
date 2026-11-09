import Foundation

/// A single ordered worker for synchronous diarization. Under pressure, emit
/// queued text without labels in order rather than stall audio or drop speech.
public final class SpeakerFinalizationQueue: @unchecked Sendable {
    private struct Job {
        let id = UUID()
        let fallback: ASRSegment
        let analyze: @Sendable () -> [ASRSegment]
        let deliver: @Sendable ([ASRSegment]) -> Void
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "dev.flowtranslate.speakers", qos: .utility)
    private let capacity: Int
    private var jobs: [Job] = []
    private var closed = false
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(capacity: Int = 3) { self.capacity = max(1, capacity) }

    /// `deliver` enqueues output only. It runs inside the ordering lock and
    /// must not call back into this queue.
    public func submit(
        fallback: ASRSegment,
        analyze: @escaping @Sendable () -> [ASRSegment],
        deliver: @escaping @Sendable ([ASRSegment]) -> Void
    ) {
        lock.withLock {
            guard !closed else { return }
            if jobs.count >= capacity {
                for job in jobs { job.deliver([job.fallback]) }
                jobs.removeAll(keepingCapacity: true)
            }
            jobs.append(Job(fallback: fallback, analyze: analyze, deliver: deliver))
            guard !running else { return }
            running = true
            worker.async { self.process() }
        }
    }

    /// Discard stale results. In-flight native inference can finish safely
    /// before this worker drops its last reference to the models.
    public func cancel() {
        lock.withLock {
            closed = true
            jobs.removeAll()
        }
    }

    public func drain() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if running { waiters.append(continuation) }
                else { continuation.resume() }
            }
        }
    }

    private func process() {
        while true {
            let job = lock.withLock { () -> Job? in
                if let first = jobs.first { return first }
                running = false
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
                return nil
            }
            guard let job else { return }
            let segments = job.analyze()
            lock.withLock {
                guard jobs.first?.id == job.id else { return }
                jobs.removeFirst()
                job.deliver(segments)
            }
        }
    }
}
