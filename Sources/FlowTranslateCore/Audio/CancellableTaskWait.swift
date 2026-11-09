import Foundation

/// Waiting for a shared/native task must not make cancellation wait for that
/// task too. A task group cannot provide this guarantee: leaving its scope
/// still joins a child whose native operation ignores cancellation.
public enum CancellableTaskWait {
    public static func wait<Value: Sendable>(
        for task: Task<Value, Never>, timeout: Duration? = nil
    ) async -> Bool {
        let completion = Completion()
        let timer = timeout.map { limit in
            Task {
                do { try await Task.sleep(for: limit) }
                catch { return }
                completion.resolve(false)
            }
        }
        let finished = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                Task {
                    _ = await task.value
                    completion.resolve(true)
                }
            }
        } onCancel: {
            completion.resolve(false)
        }
        timer?.cancel()
        return finished
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            let ready = lock.withLock { () -> Bool? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }

        func resolve(_ result: Bool) {
            let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard self.result == nil else { return nil }
                self.result = result
                let waiting = continuation
                continuation = nil
                return waiting
            }
            waiting?.resume(returning: result)
        }
    }
}
