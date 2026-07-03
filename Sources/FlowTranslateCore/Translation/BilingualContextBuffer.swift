import Foundation

/// Keeps the most recent N finalized sentences **with their translations** as
/// rolling context for the on-device LLM translator. Passing source→translation
/// pairs (instead of source-only) lets the model keep terminology, names and
/// pronouns consistent across consecutive subtitle lines.
///
/// Translations arrive asynchronously, so entries are appended source-first and
/// back-filled via `setTranslation(_:for:)` when the model returns.
public final class BilingualContextBuffer {
    public struct Entry: Sendable, Equatable {
        public let id: UUID
        public let source: String
        public var translation: String?

        public init(id: UUID, source: String, translation: String? = nil) {
            self.id = id
            self.source = source
            self.translation = translation
        }
    }

    private let capacity: Int
    private var buffer: [Entry] = []

    public init(capacity: Int = 3) {
        self.capacity = max(0, capacity)
    }

    public func append(id: UUID, source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buffer.append(Entry(id: id, source: trimmed))
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    /// Back-fill the translation for a previously appended sentence. No-op when
    /// the sentence has already been evicted (or was never appended).
    public func setTranslation(_ text: String, for id: UUID) {
        guard let i = buffer.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buffer[i].translation = trimmed
    }

    public var recent: [Entry] { buffer }

    public func reset() { buffer.removeAll() }
}
