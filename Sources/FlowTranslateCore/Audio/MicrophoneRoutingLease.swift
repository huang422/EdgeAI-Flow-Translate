import Foundation

/// A dictation borrows the router's sink without owning an existing microphone
/// source. Closing is idempotent, rejects in-flight chunks, and restores the sink.
public final class MicrophoneRoutingLease: @unchecked Sendable {
    private let router: AudioRouting
    private let previousHandler: ((AudioChunk) -> Void)?
    private let microphoneWasEnabled: Bool
    private let lock = NSLock()
    private var closed = false

    public init(router: AudioRouting, receive: @escaping (AudioChunk) -> Void) {
        self.router = router
        previousHandler = router.onChunk
        microphoneWasEnabled = router.activeSources.contains(.microphone)
        router.onChunk = { [weak self] chunk in
            guard let self, chunk.source == .microphone else { return }
            self.lock.withLock {
                guard !self.closed else { return }
                receive(chunk)
            }
        }
    }

    public func closeInput() {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        router.onChunk = previousHandler
        if !microphoneWasEnabled { router.disable(.microphone) }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// Covers cancellation both before and across a suspended device start.
    public func enableMicrophone() async throws {
        guard !isClosed else { throw CancellationError() }
        try await router.enable(.microphone)
        if isClosed {
            if !microphoneWasEnabled { router.disable(.microphone) }
            throw CancellationError()
        }
    }
}
