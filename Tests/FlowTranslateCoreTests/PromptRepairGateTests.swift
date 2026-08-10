import Foundation
import Testing
@testable import FlowTranslateCore

@Suite("Prompt repair gate — intake")
struct PromptRepairGateIntakeTests {

    @Test("a real sentence is worth repairing")
    func acceptsSentences() {
        #expect(PromptRepairGate.shouldAttempt("add a retry to the uploader"))
        #expect(PromptRepairGate.shouldAttempt("幫我加上重試機制在上傳器"))
    }

    @Test("a fragment carries nothing to repair")
    func rejectsFragments() {
        #expect(!PromptRepairGate.shouldAttempt(""))
        #expect(!PromptRepairGate.shouldAttempt("   "))
        #expect(!PromptRepairGate.shouldAttempt("ok thanks"))
    }

    /// A pasted path or command is already exactly what the user meant. Sending
    /// it to a language model can only make it wrong.
    @Test("a line that is only code is never sent to the model")
    func rejectsPureCode() {
        #expect(!PromptRepairGate.shouldAttempt("Sources/Uploader.swift"))
        #expect(!PromptRepairGate.shouldAttempt("$ swift test --filter Retry"))
        #expect(!PromptRepairGate.shouldAttempt("```"))
        #expect(!PromptRepairGate.shouldAttempt("maxRetryCount RetryPolicy.swift"))
    }

    @Test("prose that merely mentions a path is still repaired")
    func prosaicMentionsAreStillRepaired() {
        #expect(PromptRepairGate.shouldAttempt(
            "the retry logic in Sources/Uploader.swift fails on transient errors"
        ))
    }
}

@Suite("Prompt repair gate — sanitize")
struct PromptRepairGateSanitizeTests {

    @Test("labels, quotes and fences are stripped")
    func stripsDecoration() {
        #expect(PromptRepairGate.sanitize("Corrected: add a retry") == "add a retry")
        #expect(PromptRepairGate.sanitize("\"add a retry\"") == "add a retry")
        #expect(PromptRepairGate.sanitize("「加上重試」") == "加上重試")
        #expect(PromptRepairGate.sanitize("```\nadd a retry\n```") == "add a retry")
        #expect(PromptRepairGate.sanitize("修正：加上重試") == "加上重試")
    }

    @Test("a trailing remark does not cost a valid repair")
    func keepsFirstLine() {
        #expect(PromptRepairGate.sanitize("add a retry\n(no changes needed)") == "add a retry")
    }
}

@Suite("Prompt repair gate — acceptance")
struct PromptRepairGateAcceptanceTests {

    /// The repair this gate exists to allow, and the reason its edit budget is
    /// looser than the caption gate's: reconstructing a dictated identifier is
    /// a large edit measured in characters.
    @Test("a dictated identifier may be reconstructed")
    func acceptsIdentifierReconstruction() {
        #expect(PromptRepairGate.accepts(
            original: "add a retry to sources uploader dot swift",
            corrected: "add a retry to Sources/Uploader.swift"
        ))
    }

    @Test("punctuation and capitalization repairs are accepted")
    func acceptsPunctuation() {
        #expect(PromptRepairGate.accepts(
            original: "add a retry to the uploader it fails on 5xx",
            corrected: "Add a retry to the uploader; it fails on 5xx."
        ))
    }

    /// The failure with no upside. Every downstream stage would carry the
    /// inversion through faithfully.
    @Test("a flipped negation is rejected")
    func rejectsFlippedNegation() {
        #expect(PromptRepairGate.rejection(
            original: "do not add any new dependencies",
            corrected: "add any new dependencies"
        ) == .negationFlipped)

        #expect(PromptRepairGate.rejection(
            original: "add the swift-log dependency to the project",
            corrected: "do not add the swift-log dependency to the project"
        ) == .negationFlipped)
    }

    @Test("a repair that drops an identifier is rejected")
    func rejectsLostCode() {
        #expect(PromptRepairGate.rejection(
            original: "rename maxRetryCount in RetryPolicy.swift please",
            corrected: "rename the retry count in the retry policy file"
        ) == .codeLost)
    }

    @Test("a repair may add an identifier but never lose one")
    func mayAddCode() {
        #expect(PromptRepairGate.accepts(
            original: "fix the retry in retry policy swift",
            corrected: "fix the retry in RetryPolicy.swift"
        ))
    }

    @Test("a changed number is rejected")
    func rejectsChangedNumbers() {
        #expect(PromptRepairGate.rejection(
            original: "set the timeout to 30 seconds for the uploader",
            corrected: "set the timeout to 60 seconds for the uploader"
        ) == .numberChanged)
    }

    @Test("a wholesale rewrite is rejected")
    func rejectsRewrites() {
        let rejection = PromptRepairGate.rejection(
            original: "add a retry with exponential backoff to the uploader",
            corrected: "implement resilient network handling across the codebase"
        )
        #expect(rejection == .tooDifferent || rejection == .codeLost)
    }

    @Test("the model answering instead of repairing is rejected")
    func rejectsMetaAnswers() {
        #expect(PromptRepairGate.rejection(
            original: "add a retry to the uploader please",
            corrected: "Here is the corrected line: add a retry to the uploader"
        ) == .meta)
        #expect(PromptRepairGate.rejection(
            original: "add a retry to the uploader please",
            corrected: "以下是修正後的句子：加上重試"
        ) == .meta)
    }

    @Test("an unchanged line is not a repair")
    func rejectsUnchanged() {
        #expect(PromptRepairGate.rejection(
            original: "add a retry", corrected: "add a retry"
        ) == .unchanged)
    }

    @Test("halving or doubling the line is rejected")
    func rejectsLengthExtremes() {
        #expect(PromptRepairGate.rejection(
            original: "add a retry with exponential backoff to the uploader",
            corrected: "add retry"
        ) == .lengthRatio)
    }

    @Test("a multi-line answer is rejected")
    func rejectsMultiline() {
        #expect(PromptRepairGate.rejection(
            original: "add a retry to the uploader",
            corrected: "add a retry to the uploader\nand a test"
        ) == .multiline)
    }

    /// The Chinese negation vocabulary must be as protected as the English one —
    /// the whole feature is bilingual and an inversion is no less total in
    /// Chinese.
    @Test("Chinese negation is protected too")
    func protectsChineseNegation() {
        #expect(PromptRepairGate.rejection(
            original: "不要新增任何第三方套件到專案裡",
            corrected: "新增第三方套件到專案裡面去好嗎"
        ) == .negationFlipped)
    }
}

/// The gate is deliberately looser than the caption gate in one direction and
/// tighter in another. Both halves of that asymmetry are asserted, because
/// getting either backwards silently changes what reaches the compiler.
@Suite("Prompt repair gate — versus the caption gate")
struct PromptRepairGateComparisonTests {

    /// The budget matters on short lines, where one mangled term is a large
    /// fraction of the characters. `use cooper netties for deploy` →
    /// `Use Kubernetes for deployment` scores 0.379 — past the caption gate's
    /// 0.35, and exactly the repair a dictated request most needs.
    @Test("it allows a short-line term repair the caption gate would reject")
    func looserOnShortLines() {
        let pairs = [
            ("use cooper netties for deploy", "Use Kubernetes for deployment"),
            ("add re try to the up loader", "Add retry to Sources/Uploader.swift"),
        ]
        for (original, corrected) in pairs {
            #expect(
                !TranscriptCorrectionGate.accepts(original: original, corrected: corrected),
                "caption gate unexpectedly accepted \(original)"
            )
            #expect(
                PromptRepairGate.accepts(original: original, corrected: corrected),
                "prompt gate rejected \(original)"
            )
        }
    }

    @Test("it rejects an inversion the caption gate would allow")
    func tighterOnMeaning() {
        let original = "do not add any new dependencies"
        let corrected = "do add any new dependencies"
        #expect(TranscriptCorrectionGate.accepts(original: original, corrected: corrected))
        #expect(!PromptRepairGate.accepts(original: original, corrected: corrected))
    }
}

/// Reported from real use: the Tidy button appeared to do nothing on
/// code-switched Chinese. Both causes were in this gate, and each hid the other.
@Suite("Prompt repair gate — code-switched input")
struct PromptRepairGateMixedScriptTests {

    /// Mixed script has neither enough CJK to be "CJK-dominant" nor enough
    /// spaces to be counted as words, so it fell between the two intake rules
    /// and was never sent to the model at all.
    @Test("code-switched sentences are attempted")
    func mixedScriptIsAttempted() {
        let sentences = [
            "依照claude opus5的官方建議prompt寫法",
            "幫我 refactor 這個 uploadChunk function",
            "指妖出出提示詞的選項，不用其他json",
        ]
        for sentence in sentences {
            #expect(PromptRepairGate.shouldAttempt(sentence), "\(sentence)")
        }
    }

    /// Restoring case and spacing is the repair, not a violation of it.
    @Test("fixing the case and spacing of a term is allowed")
    func caseAndSpacingRepairsAreAccepted() {
        #expect(PromptRepairGate.accepts(
            original: "依照claude opus5的官方建議prompt寫法",
            corrected: "依照 Claude Opus 5 的官方建議 prompt 寫法"
        ))
        #expect(PromptRepairGate.accepts(
            original: "在 sources uploader 加上重試",
            corrected: "在 Sources/Uploader 加上重試"
        ))
    }

    /// The loosened comparison must not loosen what it exists to protect: an
    /// identifier renamed to different characters is still a lost identifier.
    @Test("a genuinely different identifier is still rejected")
    func renamedIdentifiersAreStillCaught() {
        #expect(PromptRepairGate.rejection(
            original: "rename maxRetryCount in RetryPolicy.swift please",
            corrected: "rename the retry count in the retry policy file"
        ) == .codeLost)
        #expect(PromptRepairGate.rejection(
            original: "把 OrderRepository 的查詢改掉就好",
            corrected: "把 OrderService 的查詢改掉就好"
        ) == .codeLost)
    }
}
