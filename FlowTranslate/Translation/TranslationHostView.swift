import SwiftUI
import Translation

/// Hidden host view that drives the system on-device Translation session and
/// consumes the TranslationService queue. Fully local; the first time a language
/// pair is used the system downloads the language pack (still on-device).
struct TranslationHostView: View {
    @ObservedObject var service: TranslationService
    @State private var configuration: TranslationSession.Configuration?
    @State private var configuredPair: TranslationService.LanguagePair?

    var body: some View {
        let pair = configuredPair
        return Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { @MainActor session in
                guard let pair else { return }
                // Ensure the on-device language pack is installed first (shows the
                // system download sheet on first use). Without this, translate()
                // throws and the second caption silently never appears.
                do {
                    try await session.prepareTranslation()
                } catch {
                    guard !Task.isCancelled else { return }
                    service.onUnavailable?()
                }
                guard !Task.isCancelled else { return }
                // Fresh stream for THIS session — survives language switches.
                for await pending in service.makeStream(for: pair) {
                    guard !Task.isCancelled else { return }
                    // A final sentence may already be queued while its last
                    // partial is translating. Check again at dequeue time.
                    if let cached = service.cachedTranslation(for: pending) {
                        service.complete(pending, translation: cached, from: pair)
                        continue
                    }
                    guard let target = try? await session.translate(pending.text).targetText else { continue }
                    guard !Task.isCancelled else { return }
                    service.complete(pending, translation: target, from: pair)
                }
            }
            .onAppear { resetConfiguration() }
            .onChange(of: service.targetLanguage) { _, _ in resetConfiguration() }
            .onChange(of: service.sourceLanguage) { _, _ in resetConfiguration() }
    }

    private func resetConfiguration() {
        configuredPair = service.languagePair
        // Empty source → let the framework auto-detect (used for "auto" first caption).
        let source = service.sourceLanguage.isEmpty
            ? nil : Locale.Language(identifier: service.sourceLanguage)
        configuration = TranslationSession.Configuration(
            source: source,
            target: Locale.Language(identifier: service.targetLanguage)
        )
    }
}
