import Testing
@testable import FlowTranslateCore

@Suite struct InstantPhraseTranslationsTests {
    @Test func matchesCommonPhrasesIgnoringCaseAndPunctuation() {
        #expect(InstantPhraseTranslations.lookup("Okay.", target: .traditionalChinese) == "好的。")
        #expect(InstantPhraseTranslations.lookup("THANK YOU!", target: .traditionalChinese) == "謝謝。")
        #expect(InstantPhraseTranslations.lookup("Can you hear me?", target: .traditionalChinese)
                == "你們聽得到我的聲音嗎？")
        #expect(InstantPhraseTranslations.lookup("  sounds   good  ", target: .traditionalChinese)
                == "聽起來不錯。")
    }

    @Test func apostrophePhrasesMatch() {
        #expect(InstantPhraseTranslations.lookup("You're muted.", target: .traditionalChinese) == "你靜音了。")
        #expect(InstantPhraseTranslations.lookup("I'm not sure", target: .traditionalChinese) == "我不確定。")
    }

    @Test func contentSentencesMissTheTable() {
        #expect(InstantPhraseTranslations.lookup("Okay, let's review the quarterly numbers.",
                                                 target: .traditionalChinese) == nil)
        #expect(InstantPhraseTranslations.lookup("The dashboard ships next Tuesday.",
                                                 target: .traditionalChinese) == nil)
    }

    @Test func englishTargetNeverUsesTheTable() {
        #expect(InstantPhraseTranslations.lookup("Okay.", target: .english) == nil)
    }
}
