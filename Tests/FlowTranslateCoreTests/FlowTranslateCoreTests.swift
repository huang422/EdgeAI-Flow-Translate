import Testing
@testable import FlowTranslateCore

@Test func supportedASRLanguagesIncludeDefaultLocale() {
    #expect(SupportedASRLanguages.locale(for: SupportedASRLanguages.default) != nil)
}
