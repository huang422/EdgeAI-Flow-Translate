import Foundation

/// Keeps the most recent N finalized source sentences as translation context
/// (contracts/translation.md).
public final class ContextBuffer {
    private let capacity: Int
    private var buffer: [String] = []

    public init(capacity: Int = 3) {
        self.capacity = max(0, capacity)
    }

    public func append(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buffer.append(trimmed)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    public var recent: [String] { buffer }

    public func reset() { buffer.removeAll() }
}
