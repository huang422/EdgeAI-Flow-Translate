import Foundation

/// Both capture devices use the same uptime clock. Only a new session resets
/// the origin; enabling a source later must not reset its transcript timeline.
public final class SessionAudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: TimeInterval

    public init(origin: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.origin = origin
    }

    public func begin(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock { origin = uptime }
    }

    public func relativeTime(for uptime: TimeInterval) -> TimeInterval {
        lock.withLock { max(0, uptime - origin) }
    }
}
