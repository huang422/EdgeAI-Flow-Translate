import Foundation

/// An ordered bridge from ASR workers to the UI. Draining includes delivery on
/// the MainActor, not just completion of the recognizer's background work.
public final class TranscriptEventDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    public init() {}

    public func send(_ event: TranscriptEvent, to handler: @escaping @MainActor @Sendable (TranscriptEvent) -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task { @MainActor in
                await previous?.value
                handler(event)
            }
        }
    }

    public func drain() async {
        let task = lock.withLock { tail }
        await task?.value
    }
}
