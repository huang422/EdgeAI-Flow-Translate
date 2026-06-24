import Foundation
import FlowTranslateCore

/// Real-time translation bridge: queues finalized English sentences for the
/// on-device Translation session in TranslationHostView, calling back via
/// onResult when done (FR-002).
///
/// Uses macOS's built-in Translation framework → fully local, zero model
/// management. The actual translation runs in `TranslationHostView`; a custom
/// NMT (CoreML/MLX) could replace it without touching upper layers.
@MainActor
final class TranslationService: ObservableObject {
    struct Pending: Sendable { let id: UUID; let text: String }

    @Published var sourceLanguage: String = "en"
    @Published var targetLanguage: String = "zh-Hant"
    @Published var enabled: Bool = true

    var onResult: ((UUID, String) -> Void)?
    /// Called when the on-device language pack can't be prepared (e.g. user
    /// declined the download), so the UI can tell the user translation is off.
    var onUnavailable: (() -> Void)?

    private var continuation: AsyncStream<Pending>.Continuation?
    private var buffered: [Pending] = []
    private let maxBuffered = 64

    init() {}

    func translate(id: UUID, text: String) {
        guard enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pending = Pending(id: id, text: trimmed)
        if let continuation {
            continuation.yield(pending)
        } else {
            // No active session (e.g. just after a language switch) → buffer.
            buffered.append(pending)
            if buffered.count > maxBuffered { buffered.removeFirst(buffered.count - maxBuffered) }
        }
    }

    /// Creates a FRESH request stream for a new translation session. The host
    /// view calls this each time the session (language pair) changes, so a
    /// language switch never leaves the second caption consuming a dead stream.
    func makeStream() -> AsyncStream<Pending> {
        continuation?.finish()
        return AsyncStream(bufferingPolicy: .unbounded) { cont in
            self.continuation = cont
            for pending in self.buffered { cont.yield(pending) }
            self.buffered.removeAll()
        }
    }
}
