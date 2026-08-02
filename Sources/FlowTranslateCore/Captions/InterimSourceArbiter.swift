import Foundation

/// Decides which audio source's interim (partial) text is displayed when both
/// the microphone and the system audio produce partials at the same time.
///
/// Without arbitration the two pipelines overwrite a single interim line and the
/// caption flickers between two different sentences. Policy: the active source
/// keeps the line while it is still producing updates; another source takes over
/// only after the active one has been quiet for `holdInterval` (hysteresis), or
/// immediately when the active source's utterance ends.
///
/// Pure value type with injected timestamps — fully unit-testable.
public struct InterimSourceArbiter: Equatable, Sendable {
    public var holdInterval: TimeInterval
    private var lastUpdate: [AudioSourceType: TimeInterval] = [:]
    private var active: AudioSourceType?

    public init(holdInterval: TimeInterval = 1.0) {
        self.holdInterval = holdInterval
    }

    /// The source currently owning the interim line.
    public var current: AudioSourceType? { active }

    /// Report an interim from `source` at `now`; returns the source that should
    /// own the display after this event.
    @discardableResult
    public mutating func interim(from source: AudioSourceType, at now: TimeInterval) -> AudioSourceType {
        lastUpdate[source] = now
        guard let owner = active, owner != source else {
            active = source
            return source
        }
        // Another source is talking: take over only if the owner went quiet.
        if now - (lastUpdate[owner] ?? -.infinity) > holdInterval {
            active = source
            return source
        }
        return owner
    }

    /// The utterance from `source` ended (finalized or discarded). Returns the
    /// source that should own the display next: the other source if it spoke
    /// recently, else nil.
    @discardableResult
    public mutating func end(_ source: AudioSourceType, at now: TimeInterval) -> AudioSourceType? {
        lastUpdate[source] = nil
        guard active == source else { return active }
        active = nil
        if let (other, t) = lastUpdate.max(by: { $0.value < $1.value }),
           now - t <= holdInterval {
            active = other
        }
        return active
    }

    public mutating func reset() {
        lastUpdate = [:]
        active = nil
    }
}
