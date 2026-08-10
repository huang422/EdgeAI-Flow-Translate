import Testing
@testable import FlowTranslateCore

@Suite struct TokenEstimatorTests {

    @Test func blankTextCostsNothing() {
        #expect(TokenEstimator.estimate("") == 0)
        #expect(TokenEstimator.estimate("   \n  ") == 0)
    }

    @Test func chineseCostsMoreThanEnglishForTheSameMeaning() {
        // The whole reason the compiler defaults to English output: the same
        // constraint is measurably more expensive in Chinese, because CJK
        // tokenizes near one token per character while Latin averages ~3.6.
        let english = TokenEstimator.estimate("Do not add new third-party dependencies.")
        let chinese = TokenEstimator.estimate("不要新增任何第三方相依套件。")
        #expect(chinese > english)
    }

    @Test func mixedScriptIsCountedPerClassNotPerString() {
        // A single global ratio would be wrong by roughly 3× on this input,
        // which is the ordinary case for this app.
        let mixed = "幫我 refactor 這個 function"
        let estimate = TokenEstimator.estimate(mixed)
        let allLatinOfSameLength = TokenEstimator.estimate(String(repeating: "a", count: mixed.count))
        #expect(estimate > allLatinOfSameLength)
    }

    @Test func newlinesAreChargedButSpacesAreNot() {
        // A leading space is folded into the following token by BPE, so
        // charging for it would double-count; a newline really is its own token.
        #expect(TokenEstimator.estimate("alpha beta") == TokenEstimator.estimate("alpha    beta"))
        #expect(TokenEstimator.estimate("alpha\nbeta") > TokenEstimator.estimate("alpha beta"))
    }

    @Test func denserCharacterClassesCostMorePerCharacter() {
        // The ordering that the per-class ratios exist to express, measured on
        // equal-length inputs so only density is being compared.
        //
        // Digits above Han, not below it. This test used to assert the opposite,
        // from the intuition that nothing tokenizes worse than CJK. Measured
        // against the Qwen3 BPE the app actually ships: a digit run is split one
        // token per digit (1.00 characters per token on a pure probe) while Han
        // merges common two-character words (1.29). Digits are the densest class
        // there is, and the old `digitCharsPerToken = 2.0` understated a version
        // string or a line number by half.
        let length = 36
        let letters = TokenEstimator.estimate(String(repeating: "a", count: length))
        let digits = TokenEstimator.estimate(String(repeating: "7", count: length))
        let han = TokenEstimator.estimate(String(repeating: "檔", count: length))
        #expect(letters < han)
        #expect(han < digits)
    }

    // MARK: - Script detection

    @Test func detectsCJKDominance() {
        #expect(TokenEstimator.isCJKDominant("不要新增任何第三方相依套件") == true)
        #expect(TokenEstimator.isCJKDominant("Do not add dependencies") == false)
        #expect(TokenEstimator.isCJKDominant("") == false)
        // Mostly English with a couple of Chinese words is not CJK-dominant,
        // so a code-switched request is not treated as Chinese-dominant.
        #expect(TokenEstimator.isCJKDominant("幫我 refactor 這個 function") == false)
    }

    @Test func detectsCodeSwitching() {
        #expect(TokenEstimator.isMixedScript("幫我 refactor 這個 function") == true)
        #expect(TokenEstimator.isMixedScript("純中文的需求") == false)
        #expect(TokenEstimator.isMixedScript("pure english request") == false)
    }

    // MARK: - Comparison

    @Test func comparisonReportsSavingAsPercentage() {
        let comparison = TokenComparison(before: 800, after: 300)
        #expect(comparison.saved == 500)
        #expect(comparison.savedPercent == 63)
        #expect(comparison.summary == "≈800 → ≈300 (−63%)")
    }

    @Test func comparisonSurvivesGrowthAndEmptyInput() {
        // "Optimizing" can make a prompt longer when scope exclusions get added;
        // the UI must not show a nonsensical negative-negative.
        let grew = TokenComparison(before: 100, after: 120)
        #expect(grew.savedPercent == -20)
        #expect(grew.summary == "≈100 → ≈120 (+20%)")
        #expect(TokenComparison(before: 0, after: 0).savedPercent == 0)
    }
}
