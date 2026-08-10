import Foundation
import Testing
@testable import FlowTranslateCore

@Suite struct PromptIRParserTests {

    // MARK: - Recovering JSON from model output

    @Test func parsesACleanObject() {
        let ir = PromptIRParser.parse(#"{"goal": "Add retry to the uploader"}"#)
        #expect(ir?.goal == "Add retry to the uploader")
    }

    @Test func parsesThroughAMarkdownFence() {
        let raw = """
        Here is the JSON:
        ```json
        {"goal": "Add retry", "constraints": ["No new dependencies"]}
        ```
        """
        let ir = PromptIRParser.parse(raw)
        #expect(ir?.goal == "Add retry")
        #expect(ir?.constraints == ["No new dependencies"])
    }

    @Test func skipsAPreambleObjectWithoutAGoal() {
        let raw = #"{"note": "thinking"} {"goal": "Add retry", "deliverables": ["Uploader.swift"]}"#
        let ir = PromptIRParser.parse(raw)
        #expect(ir?.goal == "Add retry")
        #expect(ir?.deliverables == ["Uploader.swift"])
    }

    @Test func bracesInsideStringsDoNotTruncateTheParse() {
        // A path, regex or template in a value would close the object early if
        // the scanner were not string-aware.
        let raw = #"{"goal": "Fix the {placeholder} bug", "constraints": ["Keep \"quotes\" intact"]}"#
        let ir = PromptIRParser.parse(raw)
        #expect(ir?.goal == "Fix the {placeholder} bug")
        #expect(ir?.constraints == [#"Keep "quotes" intact"#])
    }

    @Test func returnsNilWhenNothingUsableIsPresent() {
        #expect(PromptIRParser.parse("I could not complete that request.") == nil)
        #expect(PromptIRParser.parse(#"{"goal": ""}"#) == nil)
        #expect(PromptIRParser.parse("") == nil)
    }

    // MARK: - Tolerant decoding
    //
    // A local 4-bit model will occasionally emit the wrong shape. One slip
    // should cost that field, never the whole compile.

    @Test func acceptsAStringWhereAListWasAsked() {
        let ir = PromptIRParser.parse(#"{"goal": "Add retry", "constraints": "No new dependencies"}"#)
        #expect(ir?.constraints == ["No new dependencies"])
    }

    @Test func acceptsBareStringsForReferences() {
        let ir = PromptIRParser.parse(#"{"goal": "Add retry", "references": ["Sources/Uploader.swift"]}"#)
        #expect(ir?.references.first?.path == "Sources/Uploader.swift")
        #expect(ir?.references.first?.loadMode == .referenced)
    }

    @Test func acceptsReferenceObjectsAndLenientLoadModes() {
        let raw = #"""
        {"goal": "Add retry", "references": [
          {"path": "a.swift", "loadMode": "reference"},
          {"path": "b.swift", "loadMode": "out of scope"},
          {"path": "c.swift", "loadMode": "inline"}
        ]}
        """#
        let ir = PromptIRParser.parse(raw)
        #expect(ir?.references.map(\.loadMode) == [.referenced, .outOfScope, .loaded])
    }

    @Test func unknownTaskTypeFallsBackToNew() {
        let ir = PromptIRParser.parse(#"{"goal": "Add retry", "taskType": "invent-something"}"#)
        #expect(ir?.taskType == .new)
    }

    @Test func normalizesBlankAndRepeatedBullets() {
        let raw = #"{"goal": "Add retry", "constraints": ["a", "  ", "a", "b"]}"#
        let ir = PromptIRParser.parse(raw)
        #expect(ir?.constraints == ["a", "b"])
    }

    @Test func dropsReferencesWithNoPath() {
        let ir = PromptIRParser.parse(#"{"goal": "Add retry", "references": [{"path": "  "}]}"#)
        #expect(ir?.references.isEmpty == true)
    }

    // MARK: - Salvage

    @Test func salvageTurnsARequestIntoAThinButUsableIR() {
        // Better a thin result the user can edit than a dead end.
        let ir = PromptIRParser.salvage(from: "Add retry to the uploader. It fails on 5xx.")
        #expect(ir.isActionable)
        #expect(ir.goal == "Add retry to the uploader.")
        #expect(ir.context == ["It fails on 5xx."])
    }

    @Test func salvageOfBlankInputIsNotActionable() {
        #expect(PromptIRParser.salvage(from: "   ").isActionable == false)
    }
}

/// Generation that stops at the token cap leaves an object that never closes.
/// Everything written before the cut is still good, and throwing it away in
/// favour of a skeleton rebuilt from the raw request was the worst outcome
/// available — the expensive part had already run.
@Suite("Truncated output recovery")
struct TruncatedRecoveryTests {

    @Test("the completed fields survive a cut mid-value")
    func recoversCompletedFields() {
        let raw = """
        {"taskType":"refine","goal":"Add exponential-backoff retry to the uploader",\
        "context":["Sources/Uploader.swift fails on transient 5xx"],\
        "constraints":["NO_DEPS","TEST_
        """
        let ir = PromptIRParser.recoverTruncated(raw)
        #expect(ir?.goal == "Add exponential-backoff retry to the uploader")
        #expect(ir?.context == ["Sources/Uploader.swift fails on transient 5xx"])
        // The half-written bullet is gone; the complete one before it is not.
        #expect(ir?.constraints == ["NO_DEPS"])
    }

    @Test("a cut between fields keeps everything before it")
    func recoversAtAFieldBoundary() {
        let raw = """
        {"taskType":"debug","goal":"Find why the parser throws on empty input",\
        "context":["line 412"],"acceptance":
        """
        let ir = PromptIRParser.recoverTruncated(raw)
        #expect(ir?.goal == "Find why the parser throws on empty input")
        #expect(ir?.context == ["line 412"])
        #expect(ir?.acceptance.isEmpty == true)
    }

    /// A goal cut in the middle reads as a finished instruction. A wrong
    /// instruction that looks deliberate is worse than a missing one, so a
    /// half-written string is never closed and guessed at.
    @Test("a half-written goal is not completed by guessing")
    func doesNotInventAGoal() {
        #expect(PromptIRParser.recoverTruncated("{\"goal\":\"Delete every file in") == nil)
    }

    @Test("balanced output is left to the ordinary parser")
    func ignoresCompleteObjects() {
        #expect(PromptIRParser.recoverTruncated("{\"goal\":\"Ship it\"}") == nil)
        #expect(PromptIRParser.parse("{\"goal\":\"Ship it\"}")?.goal == "Ship it")
    }

    @Test("truncation is still detected")
    func detectsTruncation() {
        #expect(PromptIRParser.looksTruncated("{\"goal\":\"a\",\"context\":[\"b"))
        #expect(!PromptIRParser.looksTruncated("{\"goal\":\"a\"}"))
    }
}
