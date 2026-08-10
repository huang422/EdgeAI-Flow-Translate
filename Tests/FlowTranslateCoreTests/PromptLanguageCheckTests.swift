import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct PromptLanguageCheckTests {

    private let chinese = PromptIR(
        goal: "把重試機制加到上傳器",
        context: ["Sources/Uploader.swift 在 5xx 會失敗"]
    )
    private let english = PromptIR(
        goal: "Add exponential-backoff retry to the uploader",
        context: ["Sources/Uploader.swift fails on transient 5xx"]
    )

    @Test func chineseBodyUnderAnEnglishSettingIsFlagged() {
        #expect(PromptLanguageCheck.mismatches(chinese, expected: .english))
    }

    @Test func englishBodyUnderAChineseSettingIsFlagged() {
        #expect(PromptLanguageCheck.mismatches(english, expected: .traditionalChinese))
    }

    @Test func matchingLanguagesAreNotFlagged() {
        #expect(!PromptLanguageCheck.mismatches(english, expected: .english))
        #expect(!PromptLanguageCheck.mismatches(chinese, expected: .traditionalChinese))
    }

    /// An English brief may quote a Chinese error message without being Chinese.
    @Test func aQuotedChinesePhraseInEnglishProseIsNotFlagged() {
        let ir = PromptIR(
            goal: "Fix the crash that shows the message 「無法載入模型」 on launch",
            context: ["It reproduces on a cold start with no network"]
        )
        #expect(!PromptLanguageCheck.mismatches(ir, expected: .english))
    }

    /// Constraints are symbols or rulebook wording, so their language says
    /// nothing about what the model wrote.
    @Test func constraintsAreNotEvidence() {
        let ir = PromptIR(goal: "把重試加到上傳器", constraints: ["NO_DEPS", "TEST_PASS"])
        #expect(PromptLanguageCheck.mismatches(ir, expected: .english))
    }

    @Test func tooLittleProseIsNeverFlagged() {
        #expect(!PromptLanguageCheck.mismatches(PromptIR(goal: "修好"), expected: .english))
        #expect(!PromptLanguageCheck.mismatches(PromptIR(), expected: .traditionalChinese))
    }

    /// The question field counts too — a question is the whole request when
    /// there is no task beside it.
    @Test func aQuestionOnlyPromptIsChecked() {
        let ir = PromptIR(question: "為何第二字幕會跳動？finalize 有 bug 嗎？")
        #expect(PromptLanguageCheck.mismatches(ir, expected: .english))
    }
}
