import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct LexicalCompressorTests {

    // MARK: - The invariants that matter most
    //
    // A compressor that silently inverts an instruction is worse than no
    // compressor at all, so these hold for the shipped profile and for a bare
    // one built by hand.

    @Test func negationSurvivesEveryProfile() {
        let cases = [
            "Do not add any new third-party dependencies to this project",
            "Never rename the exported functions",
            "The parser should not be modified under any circumstances",
        ]
        for profile in [CompressionProfile.balanced, CompressionProfile()] {
            for text in cases {
                let out = LexicalCompressor.compress(text, level: .free, profile: profile)
                #expect(
                    out.lowercased().contains("not") || out.lowercased().contains("never")
                        || out.lowercased().contains("n't"),
                    "negation lost: \(out)"
                )
            }
        }
    }

    @Test func questionWordsAndQuestionMarkSurvive() {
        let out = LexicalCompressor.compress(
            "Why does the uploader fail on transient errors?", level: .free, profile: .balanced
        )
        #expect(out.lowercased().contains("why"))
        #expect(out.hasSuffix("?"))
    }

    @Test func codeIdentifiersAndPathsAreNeverTouched() {
        let text = "Update Sources/Uploader.swift and the maxRetryCount constant using --verbose"
        for profile in [CompressionProfile.balanced, CompressionProfile()] {
            let out = LexicalCompressor.compress(text, level: .free, profile: profile)
            #expect(out.contains("Sources/Uploader.swift"))
            #expect(out.contains("maxRetryCount"))
            #expect(out.contains("--verbose"))
        }
    }

    @Test func numbersAndVersionsSurvive() {
        let out = LexicalCompressor.compress(
            "Retry up to 3 times with a 500 ms backoff on HTTP 503", level: .free, profile: .balanced
        )
        #expect(out.contains("3"))
        #expect(out.contains("500"))
        #expect(out.contains("503"))
    }

    @Test func ruleSymbolsSurvive() {
        // A bare NO_DEPS in a constraint must not be pruned into nothing.
        let out = LexicalCompressor.compress("NO_DEPS and MIN_DIFF", level: .free, profile: .balanced)
        #expect(out.contains("NO_DEPS"))
        #expect(out.contains("MIN_DIFF"))
    }

    @Test func namedEntitiesArePreserved() {
        let out = LexicalCompressor.compress(
            "Ask the New York team before changing this", level: .free, profile: .balanced
        )
        #expect(out.contains("New York"))
    }

    // MARK: - Levels

    @Test func protectedLevelIsByteForByte() {
        let text = #"{"sentiment": "positive|negative", "confidence": 0.0-1.0}"#
        #expect(LexicalCompressor.compress(text, level: .protected, profile: .balanced) == text)
    }

    @Test func carefulLevelNeverPrunesWords() {
        // Constraints go through `careful`; an article removed here could shift
        // "the parser" into "parser" and lose which one was meant.
        let text = "Do not change the public API of the uploader module"
        let out = LexicalCompressor.compress(text, level: .careful, profile: .balanced)
        #expect(out.contains("the public API"))
        #expect(out.contains("the uploader module"))
    }

    @Test func freeLevelActuallyCompresses() {
        let text = "I was wondering if you could please basically just add a retry to the uploader"
        let before = TokenEstimator.estimate(text)
        let after = TokenEstimator.estimate(
            LexicalCompressor.compress(text, level: .free, profile: .balanced)
        )
        #expect(after < before)
    }

    /// There is one shipped profile now, so what is worth pinning is that it
    /// actually compresses — not the ordering of three presets whose outer two
    /// nobody could choose between.
    @Test func theShippedProfileCompresses() {
        let text = "I was wondering if you could basically just update the documentation "
            + "for the configuration parameters that are currently in the repository"
        let uncompressed = TokenEstimator.estimate(
            LexicalCompressor.compress(text, level: .free, profile: CompressionProfile()))
        let balanced = TokenEstimator.estimate(
            LexicalCompressor.compress(text, level: .free, profile: .balanced))
        #expect(balanced < uncompressed)
    }

    // MARK: - Individual techniques

    @Test func removesFillerPhrases() {
        let out = LexicalCompressor.removeFillerPhrases("I was wondering if you could explain this")
        #expect(out.contains("wondering") == false)
        #expect(out.contains("explain"))
    }

    @Test func appliesAbbreviationsAndContractions() {
        #expect(LexicalCompressor.applyPhraseMap("for example this", LexicalCompressor.abbreviations)
            .contains("e.g."))
        #expect(LexicalCompressor.applyPhraseMap("in order to ship", LexicalCompressor.abbreviations)
            .hasPrefix("to ship"))
        #expect(LexicalCompressor.applyPhraseMap("do not ship", LexicalCompressor.contractions)
            .contains("don't"))
    }

    @Test func removesFillerWords() {
        let out = LexicalCompressor.removeWords(
            "this is basically really just fine", LexicalCompressor.fillerWords
        )
        #expect(out.contains("basically") == false)
        #expect(out.contains("really") == false)
        #expect(out.contains("fine"))
    }

    @Test func contractionsAreStillReadAsNegation() {
        // `applyContractions` turns "do not" into "don't"; the protection list
        // has to recognise the contracted form or the next stage would prune it.
        #expect(LexicalCompressor.isProtected("don't"))
        #expect(LexicalCompressor.isProtected("doesn't"))
    }

    @Test func lemmatizationShortensButKeepsMeaning() {
        let out = LexicalCompressor.compress(
            "The tests were running slowly", level: .free, profile: .balanced
        )
        #expect(out.lowercased().contains("test"))
    }

    @Test func synonymsShortenKnownVerboseWords() {
        let out = LexicalCompressor.compress(
            "Utilize the configuration to obtain approximately the same result",
            level: .free, profile: .balanced
        )
        #expect(out.lowercased().contains("utilize") == false)
        #expect(out.lowercased().contains("config") || out.lowercased().contains("use"))
    }

    @Test func normalizationTidiesSpacingAndPunctuation() {
        #expect(LexicalCompressor.normalize("hello   world !!!") == "hello world!")
        #expect(LexicalCompressor.normalize("a  ,  b") == "a, b")
    }

    // MARK: - Chinese

    @Test func chineseSkipsTaggingStagesRatherThanGuessing() {
        // NLTagger returns `OtherWord` for every Chinese token and offers no
        // lemma or name type, so pruning by grammatical role is not available.
        // Skipping is the honest behaviour; the text must come back intact.
        let text = "不要新增任何第三方相依套件，並且保持公開介面不變"
        let out = LexicalCompressor.compress(text, level: .free, profile: .balanced,
                                             language: .traditionalChinese)
        #expect(out.contains("不要"))
        #expect(out.contains("第三方相依套件"))
        #expect(out.contains("公開介面"))
    }

    @Test func mixedScriptKeepsBothHalvesIntact() {
        let text = "幫我 refactor 這個 function，不要動到 API"
        let out = LexicalCompressor.compress(text, level: .free, profile: .balanced)
        #expect(out.contains("refactor"))
        #expect(out.contains("API"))
        #expect(out.contains("不要"))
    }

    // MARK: - Structure

    @Test func newlinesAndListStructureSurvive() {
        let text = "First item\nSecond item\nThird item"
        let out = LexicalCompressor.compress(text, level: .free, profile: .balanced)
        #expect(out.components(separatedBy: "\n").count == 3)
    }

    @Test func emptyAndBlankInputAreReturnedUnchanged() {
        #expect(LexicalCompressor.compress("", level: .free, profile: .balanced) == "")
        #expect(LexicalCompressor.compress("   ", level: .free, profile: .balanced) == "   ")
    }

    @Test func compressionNeverReturnsEmptyForRealInput() {
        // Pruning everything would silently delete the instruction.
        for text in ["the a an is", "just really basically"] {
            #expect(
                LexicalCompressor.compress(text, level: .free, profile: .balanced).isEmpty == false
            )
        }
    }
}

/// Contractions English does not allow at the end of a clause.
@Suite struct StrandedContractionTests {
    private func compress(_ text: String) -> String {
        LexicalCompressor.compress(text, level: .careful, profile: .balanced, language: .english)
    }

    /// Shipped in the rulebook's own MIN_DIFF wording as "exactly as it's."
    @Test func aCopulaAtTheEndOfASentenceIsNotContracted() {
        #expect(compress("Leave untouched code exactly as it is.").contains("as it is"))
    }

    @Test func aCopulaBeforeAClauseBreakIsNotContracted() {
        #expect(compress("Leave it as it is, then run the tests.").contains("as it is,"))
    }

    @Test func aMidSentenceCopulaStillContracts() {
        #expect(compress("Check that it is a valid path.").contains("it's"))
    }

    @Test func negativesContractAnywhere() {
        #expect(compress("Run the tests. If they fail, do not.").contains("don't"))
    }
}
