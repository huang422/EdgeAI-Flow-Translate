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
    struct LanguagePair: Hashable, Sendable {
        let source: String
        let target: String
    }

    struct Pending: Sendable {
        let id: UUID
        let text: String
        let pair: LanguagePair
    }

    private struct RequestKey: Hashable {
        let pair: LanguagePair
        let text: String
    }

    @Published var sourceLanguage: String = "en"
    @Published var targetLanguage: String = "zh-Hant"
    @Published var enabled: Bool = true

    var languagePair: LanguagePair { LanguagePair(source: sourceLanguage, target: targetLanguage) }

    var onResult: ((UUID, String) -> Void)?
    /// Called when the on-device language pack can't be prepared (e.g. user
    /// declined the download), so the UI can tell the user translation is off.
    var onUnavailable: (() -> Void)?

    private var continuation: AsyncStream<Pending>.Continuation?
    private var streamPair: LanguagePair?
    private var buffered: [Pending] = []
    private let maxBuffered = 64
    // Apple translates each input independently. Reusing an exact completed
    // input avoids translating the last partial again when it becomes final.
    // Language pairs are part of the key; the small FIFO stays bounded.
    private var completed: [RequestKey: String] = [:]
    private var completedOrder: [RequestKey] = []

    init() {}

    func translate(id: UUID, text: String) {
        guard enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pending = Pending(id: id, text: trimmed, pair: languagePair)
        if let cached = cachedTranslation(for: pending) {
            onResult?(id, cached)
            return
        }
        if let continuation, streamPair == pending.pair {
            continuation.yield(pending)
        } else {
            // No active session (e.g. just after a language switch) → buffer.
            buffered.append(pending)
            if buffered.count > maxBuffered { buffered.removeFirst(buffered.count - maxBuffered) }
        }
    }

    func cachedTranslation(for pending: Pending) -> String? {
        completed[key(for: pending)]
    }

    func complete(_ pending: Pending, translation: String, from pair: LanguagePair) {
        guard pending.pair == pair,
              !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = key(for: pending)
        if completed[key] == nil {
            completedOrder.append(key)
            if completedOrder.count > maxBuffered {
                completed.removeValue(forKey: completedOrder.removeFirst())
            }
        }
        completed[key] = translation
        onResult?(pending.id, translation)
    }

    private func key(for pending: Pending) -> RequestKey {
        RequestKey(pair: pending.pair, text: pending.text)
    }

    /// Creates a FRESH request stream for a new translation session. The host
    /// view calls this each time the session (language pair) changes, so a
    /// language switch never leaves the second caption consuming a dead stream.
    func makeStream(for pair: LanguagePair) -> AsyncStream<Pending> {
        // An obsolete session may finish preparing after its replacement. It
        // must not take the current session's continuation away.
        guard pair == languagePair else { return AsyncStream { $0.finish() } }
        continuation?.finish()
        streamPair = pair
        return AsyncStream(bufferingPolicy: .unbounded) { cont in
            self.continuation = cont
            for pending in self.buffered where pending.pair == pair { cont.yield(pending) }
            self.buffered.removeAll { $0.pair == pair }
        }
    }
}
