import Foundation

/// Stop, window close and application termination share one asynchronous drain.
@MainActor public final class MeetingStopCoordinator {
    private var task: Task<Void, Never>?
    public var isRunning: Bool { task != nil }
    public init() {}

    public func run(_ work: @escaping @MainActor () async -> Void) async {
        if let task { await task.value; return }
        let task = Task { @MainActor in await work() }
        self.task = task
        await task.value
        self.task = nil
    }
}
