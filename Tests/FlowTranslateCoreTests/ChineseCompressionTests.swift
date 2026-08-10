import Foundation
import Testing
@testable import FlowTranslateCore

/// Chinese used to be compressed by essentially nothing: the filler list was
/// English and matched on `\b` word boundaries, which never occur in Chinese, so
/// the one technique that *is* safe without part-of-speech tagging was a no-op.
@Suite("Chinese compression")
struct ChineseCompressionTests {

    private func compress(_ text: String) -> String {
        LexicalCompressor.compress(
            text, level: .free, profile: .balanced, language: .traditionalChinese
        )
    }

    @Test("politeness and hedging are removed")
    func courtesyIsRemoved() {
        let cases = [
            ("麻煩你幫我加上重試機制", "加上重試機制"),
            ("我想說是不是可以重構這段", "重構這段"),
            ("請你幫我看一下報表產生器", "報表產生器"),
        ]
        for (input, expected) in cases {
            #expect(compress(input) == expected, "\(input) → \(compress(input))")
        }
    }

    @Test("compression is material, not cosmetic")
    func savingIsReal() {
        let input = "我想說是不是可以幫我看一下報表產生器，基本上跑 1000 筆要 30 秒，其實太慢了"
        let before = TokenEstimator.estimate(input)
        let after = TokenEstimator.estimate(compress(input))
        #expect(after < before)
        // Half the tokens on a realistically padded spoken request.
        #expect(Double(after) / Double(before) < 0.75, "\(before) → \(after)")
    }

    /// The whole point of the guard rails: courtesy goes, meaning stays.
    @Test("negation, modality, numbers and identifiers survive")
    func meaningIsPreserved() {
        let input = "麻煩你幫我改 OrderRepository，不要新增套件，逾時必須設 30 秒"
        let output = compress(input)
        #expect(output.contains("不要"))
        #expect(output.contains("必須"))
        #expect(output.contains("30"))
        #expect(output.contains("OrderRepository"))
        #expect(!output.contains("麻煩你"))
    }

    /// A compound marker must not be half-eaten. `然後就是` is removed before
    /// `就是說` by length, which left `然後就是說` as a stranded `說`.
    @Test("compound discourse markers are removed whole")
    func compoundMarkersAreRemovedWhole() {
        let output = compress("重構這段，然後就是說測試都要過")
        #expect(!output.contains("說測試"), "\(output)")
        #expect(output.contains("測試都要過"))
    }

    @Test("English is unaffected by the Chinese pass")
    func englishIsUnchanged() {
        let english = LexicalCompressor.compress(
            "Could you please add a retry to the uploader",
            level: .free, profile: .balanced, language: .english
        )
        #expect(english.lowercased().contains("retry"))
        #expect(!english.lowercased().contains("could you please"))
    }

    /// Constraints are `careful`, and courtesy removal is safe there too — but
    /// nothing that prunes meaning may run.
    @Test("careful level still removes courtesy")
    func carefulLevelStillHelps() {
        let output = LexicalCompressor.compress(
            "麻煩你不要新增任何第三方套件",
            level: .careful, profile: .balanced, language: .traditionalChinese
        )
        #expect(!output.contains("麻煩你"))
        #expect(output.contains("不要新增任何第三方套件"))
    }
}
