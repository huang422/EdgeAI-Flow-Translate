import Foundation
import Testing
@testable import FlowTranslateCore

/// The locale list and the numbers quoted about it in comments, Settings and the
/// README drifted apart when `zh-TW` was removed: three places still said 33.
/// Pinning the counts here makes the next change to the list fail loudly instead
/// of leaving stale documentation behind.
@Suite("Supported ASR languages")
struct SupportedLanguagesTests {

    @Test("the advertised counts match the list")
    func countsMatchTheList() {
        #expect(SupportedASRLanguages.transcriptionReady.count == 19)
        #expect(SupportedASRLanguages.broadCoverage.count == 13)
        #expect(SupportedASRLanguages.all.count == 32)
    }

    /// No shipped model variant's tokenizer carries a `zh-TW` tag, so offering it
    /// left the language lock searching for something that does not exist and the
    /// decoder producing garbage. Traditional output comes from the script guard.
    @Test("Mandarin has exactly one entry, and it is the tag the model has")
    func oneMandarinEntry() {
        let mandarin = SupportedASRLanguages.all.filter { $0.code.hasPrefix("zh") }
        #expect(mandarin.map(\.code) == ["zh-CN"])
    }

    /// The picker's order is a product decision, not the model's quality order:
    /// Mandarin and Swedish live in `broadCoverage`, so tier order buried them
    /// under nineteen rows the user scrolls past every time.
    @Test("English leads, then the promoted locales, then the tiers")
    func pickerOrderPutsTheCommonChoicesFirst() {
        let codes = SupportedASRLanguages.all.map(\.code)
        // 英文 · 中文 · 瑞典文 · 韓文 · 日文
        #expect(Array(codes.prefix(6))
                == ["en-US", "en-GB", "zh-CN", "sv-SE", "ko-KR", "ja-JP"])
        // Everything else keeps its tier order behind them.
        #expect(codes.dropFirst(6).first == "es-US")
        // Reordering must not drop or duplicate anything.
        #expect(Set(codes) == Set(
            (SupportedASRLanguages.transcriptionReady
             + SupportedASRLanguages.broadCoverage).map(\.code)
        ))
    }

    @Test("every code is unique and resolvable")
    func codesAreUniqueAndResolvable() {
        let codes = SupportedASRLanguages.all.map(\.code)
        #expect(Set(codes).count == codes.count)
        for code in codes {
            #expect(SupportedASRLanguages.locale(for: code)?.code == code)
        }
        #expect(SupportedASRLanguages.locale(for: "zh-TW") == nil)
    }

    /// A stored `zh-TW` from before the removal has to migrate, or the language
    /// lock searches for a tag no variant defines.
    @Test("a persisted zh-TW migrates to the tag that exists")
    func storedTaiwanTagMigrates() throws {
        let json = #"{"firstLanguage":"zh-TW"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: json)
        #expect(decoded.firstLanguage == "zh-CN")
    }
}
