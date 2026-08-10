import XCTest
@testable import FlowTranslateCore

/// Several questions in one breath, and requests that both ask and instruct.
final class QuestionSplitTests: XCTestCase {

    // MARK: - Splitting the question field

    func testASingleQuestionStaysWhole() {
        let ir = PromptIR(question: "為什麼字幕會跳動？")
        XCTAssertEqual(ir.questions, ["為什麼字幕會跳動？"])
    }

    func testTwoQuestionsBecomeTwoItems() {
        let ir = PromptIR(question: "task 跟 question 怎麼分的？為何只會出現一種？")
        XCTAssertEqual(ir.questions.count, 2)
        XCTAssertTrue(ir.questions[0].contains("怎麼分"))
        XCTAssertTrue(ir.questions[1].contains("只會出現一種"))
    }

    func testAPremiseStaysWithItsQuestion() {
        // "字幕會跳動" asks nothing. As an item of its own it would be a numbered
        // question with no question in it.
        let ir = PromptIR(question: "字幕會跳動。為什麼？")
        XCTAssertEqual(ir.questions.count, 1)
        XCTAssertTrue(ir.questions[0].contains("字幕會跳動"))
        XCTAssertTrue(ir.questions[0].contains("為什麼"))
    }

    func testTrailingNonQuestionIsKeptNotDropped() {
        let ir = PromptIR(question: "要用哪一個？我沒有偏好。")
        XCTAssertEqual(ir.questions.count, 1)
        XCTAssertTrue(ir.questions[0].contains("我沒有偏好"))
    }

    func testEmptyQuestionYieldsNothing() {
        XCTAssertEqual(PromptIR(question: "   ").questions, [])
    }

    func testMultipleQuestionsAreNumberedInTheRenderedPrompt() {
        let ir = PromptIR(question: "為什麼會跳動？要怎麼修？")
        let prompt = PromptRenderer.render(
            ir, options: .init(kind: .prompt, symbolMode: .off)
        ).content
        XCTAssertTrue(prompt.contains("1."), prompt)
        XCTAssertTrue(prompt.contains("2."), prompt)
    }

    func testOneQuestionIsNotNumbered() {
        let ir = PromptIR(question: "為什麼會跳動？")
        let prompt = PromptRenderer.render(
            ir, options: .init(kind: .prompt, symbolMode: .off)
        ).content
        XCTAssertFalse(prompt.contains("1."), prompt)
    }

    // MARK: - Classification of a request that asks *and* instructs

    func testAMixedRequestKeepsItsWork() {
        // The regression: `為何` made the whole request a question, so the model's
        // goal was blanked and the instruction disappeared from the prompt.
        let ir = PromptIR(goal: "修好 finalize")
        let result = PromptIRParser.classifying(ir, from: "為何字幕會跳動？順便把 finalize 修好。")
        XCTAssertEqual(result.goal, "修好 finalize")
        XCTAssertTrue(result.question.contains("為何字幕會跳動"))
        XCTAssertFalse(result.question.contains("順便"))
    }

    func testAPureQuestionBlanksTheInventedGoal() {
        let ir = PromptIR(goal: "說明字幕跳動的原因")
        let result = PromptIRParser.classifying(ir, from: "為何字幕會跳動？")
        XCTAssertEqual(result.goal, "")
        XCTAssertTrue(result.isPureQuestion)
    }

    func testAQuestionTheModelAlreadyFoundIsLeftAlone() {
        let ir = PromptIR(goal: "修好 finalize", question: "為何會跳動？")
        let result = PromptIRParser.classifying(ir, from: "為何字幕會跳動？順便把 finalize 修好。")
        XCTAssertEqual(result, ir)
    }

    func testAnInstructionIsNotTurnedIntoAQuestion() {
        let ir = PromptIR(goal: "把重試加到 Uploader.swift")
        let result = PromptIRParser.classifying(ir, from: "把重試加到 Uploader.swift。")
        XCTAssertEqual(result, ir)
    }

    func testEveryQuestionInAMultiQuestionRequestIsKept() {
        let ir = PromptIR(goal: "比較兩種做法")
        let result = PromptIRParser.classifying(
            ir, from: "task 跟 question 怎麼分的？為何只會出現一種？"
        )
        XCTAssertEqual(result.questions.count, 2)
    }
}
