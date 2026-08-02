import Foundation
import Network
import os

/// One-shot network reachability check, used to fail fast with a clear message
/// before a model download is attempted while offline (instead of hanging for
/// a 60 s+ URLSession timeout on "Loading model… 0%").
enum NetworkCheck {
    /// Resolves with the current path status (true = some network is available).
    /// Times out defensively after 2 s (treats an unresponsive monitor as online,
    /// so a false negative can never block a user who actually has connectivity).
    static func isOnline() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            // NWPathMonitor may call its handler multiple times (and the timeout
            // races it) — resume the continuation exactly once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { online in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                monitor.cancel()
                cont.resume(returning: online)
            }
            monitor.pathUpdateHandler = { path in
                finish(path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                finish(true)
            }
        }
    }
}
