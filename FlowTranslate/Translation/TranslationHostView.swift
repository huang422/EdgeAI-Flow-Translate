import SwiftUI
import Translation

/// Hidden host view that drives the system on-device Translation session and
/// consumes the TranslationService queue. Fully local; the first time a language
/// pair is used the system downloads the language pack (still on-device).
struct TranslationHostView: View {
    @ObservedObject var service: TranslationService
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { @MainActor session in
                // Ensure the on-device language pack is installed first (shows the
                // system download sheet on first use). Without this, translate()
                // throws and the second caption silently never appears.
                do {
                    try await session.prepareTranslation()
                } catch {
                    service.onUnavailable?()
                }
                // Fresh stream for THIS session — survives language switches.
                for await pending in service.makeStream() {
                    guard let target = try? await session.translate(pending.text).targetText else { continue }
                    service.onResult?(pending.id, target)
                }
            }
            .onAppear { resetConfiguration() }
            .onChange(of: service.targetLanguage) { _, _ in resetConfiguration() }
            .onChange(of: service.sourceLanguage) { _, _ in resetConfiguration() }
    }

    private func resetConfiguration() {
        // Empty source → let the framework auto-detect (used for "auto" first caption).
        let source = service.sourceLanguage.isEmpty
            ? nil : Locale.Language(identifier: service.sourceLanguage)
        configuration = TranslationSession.Configuration(
            source: source,
            target: Locale.Language(identifier: service.targetLanguage)
        )
    }
}
