import Foundation
import Testing
@testable import FlowTranslateCore

/// A question compiled as a task is not a degraded answer — it is the opposite
/// of what was asked. "Where do the exported files go?" became a prompt telling
/// Claude to go and move files, and the prompt read perfectly well, so nothing
/// downstream caught it.
@Suite("Questions stay questions")
struct QuestionPromptTests {

    private func render(_ ir: PromptIR, language: PromptOutputLanguage = .english) -> String {
        PromptRenderer.render(
            ir, options: PromptRenderOptions(language: language, detail: .full)
        ).content
    }

    @Test("a question renders under its own tag, not as a task")
    func questionsGetTheirOwnTag() {
        let content = render(PromptIR(
            question: "Where must the exported files go for the rulebook to take effect?"
        ))
        #expect(content.contains("<question>"))
        #expect(!content.contains("<task>"))
    }

    /// Anthropic's own "sample prompt for conservative action", which the guide
    /// offers for exactly this situation.
    @Test("a question carries the answer-first instruction")
    func questionsSayNotToAct() {
        let content = render(PromptIR(question: "Which mode should I use?"))
        #expect(content.contains("<answer_first>"))
        #expect(content.contains("Do not jump into implementation"))
        #expect(content.contains("default to providing information"))
    }

    /// The case a single question-or-task classification could not represent:
    /// "為何字幕會跳動？順便把 finalize 修好" asks something *and* asks for work,
    /// and one field meant the second half was dropped or the question was
    /// rewritten as a command, depending on which way the classifier fell.
    @Test("a request that asks and instructs renders both tags")
    func bothAxesCanCoexist() {
        let content = render(PromptIR(
            goal: "Fix the finalize bug behind the flicker",
            question: "Why does the second caption flicker?"
        ))
        #expect(content.contains("<question>"))
        #expect(content.contains("<task>"))
        // The question comes first: it is what has to be dealt with before the
        // work makes sense.
        let q = content.range(of: "<question>").map { content.distance(from: content.startIndex, to: $0.lowerBound) } ?? -1
        let t = content.range(of: "<task>").map { content.distance(from: content.startIndex, to: $0.lowerBound) } ?? -1
        #expect(q < t, "\(content)")
    }

    /// "Do not act" would contradict the `<task>` tag directly above it, so a
    /// request with work attached gets the ordering instruction instead of the
    /// prohibition.
    @Test("the answer-first wording depends on whether there is work to do")
    func answerFirstAdaptsToTheTask() {
        let pure = render(PromptIR(question: "Which mode should I use?"))
        #expect(pure.contains("Do not jump into implementation"))

        let both = render(PromptIR(
            goal: "Switch it to the faster mode", question: "Which mode should I use?"
        ))
        #expect(both.contains("<answer_first>"))
        #expect(!both.contains("Do not jump into implementation"), "\(both)")
        #expect(both.contains("Answer the question before starting the work"))
    }

    /// A pure question has the strongest boundary there is already. One that also
    /// asks for work does not, and still gets the scope nag.
    @Test("only a pure question skips the scope nag")
    func scopeNagFollowsTheWork() {
        let pure = PromptIR(question: "Which mode should I use?")
        #expect(!PromptOptimizer.lint(pure).contains { $0.rule == .missingScopeExclusions })

        let both = PromptIR(goal: "Switch to the faster mode", question: "Which is faster?")
        #expect(PromptOptimizer.lint(both).contains { $0.rule == .missingScopeExclusions })
    }

    /// A model that answered the older single-axis schema is read the way it
    /// meant it, rather than losing the whole compile to a shape change.
    @Test("the older single-axis output still decodes")
    func legacyShapeMigrates() {
        let ir = PromptIRParser.parse(
            #"{"taskType":"question","goal":"Where do the files go?"}"#
        )
        #expect(ir?.question == "Where do the files go?")
        #expect(ir?.goal.isEmpty == true)
    }

    /// Salvage runs when there is no model answer at all, and a request that both
    /// asks and instructs is common enough that collapsing it either way loses
    /// half of what was said.
    @Test("salvage splits a mixed request across both fields")
    func salvageSplitsBothAxes() {
        let ir = PromptIRParser.salvage(
            from: "Why does the second caption flicker? Fix the finalize bug too."
        )
        #expect(ir.question.contains("Why does the second caption flicker?"))
        #expect(ir.goal == "Fix the finalize bug too.")
    }

    @Test("a task carries neither")
    func tasksAreUnaffected() {
        let content = render(PromptIR(taskType: .refine, goal: "Add a retry to the uploader"))
        #expect(content.contains("<task>"))
        #expect(!content.contains("<question>"))
        #expect(!content.contains("answer_first"))
    }

    /// The compressor's job is to shorten prose without changing meaning, and on
    /// a question it can drop the word being asked about.
    @Test("a question is never pruned")
    func questionWordingIsProtected() {
        let question = "Why does the second caption disappear and then come back?"
        let content = PromptRenderer.render(
            PromptIR(question: question),
            options: PromptRenderOptions(compression: .balanced)
        ).content
        #expect(content.contains(question))
    }

    @Test("the Chinese rendering says the same thing")
    func chineseQuestionsWork() {
        let content = render(
            PromptIR(question: "檔案要匯出到哪裡才會生效？"),
            language: .traditionalChinese
        )
        #expect(content.contains("<question>"))
        #expect(content.contains("先回答問題"))
    }

    /// A question has the strongest boundary a prompt can have already. Nagging
    /// about missing scope exclusions there is advice about work nobody asked for.
    @Test("a question is not nagged about scope exclusions")
    func noScopeNagOnQuestions() {
        let question = PromptIR(question: "Which mode should I use?")
        #expect(!PromptOptimizer.lint(question).contains { $0.rule == .missingScopeExclusions })
        let task = PromptIR(taskType: .new, goal: "Add a retry")
        #expect(PromptOptimizer.lint(task).contains { $0.rule == .missingScopeExclusions })
    }
}

/// The model is asked to classify this and mostly will not — a 4-bit 4B model
/// answers `new` for almost anything — so the deterministic signal overrides it.
@Suite("Question detection")
struct QuestionDetectorTests {

    @Test("a question mark in either width is decisive")
    func punctuationDecides() {
        #expect(QuestionDetector.isQuestion("Where do the files go?"))
        #expect(QuestionDetector.isQuestion("檔案要放哪裡？"))
        #expect(!QuestionDetector.isQuestion("Move the files to build/"))
    }

    /// Dictation loses the question mark constantly, which is why punctuation
    /// cannot be the only signal.
    @Test("an interrogative opener works without punctuation")
    func openersWork() {
        #expect(QuestionDetector.isQuestion("why does the second caption disappear"))
        #expect(QuestionDetector.isQuestion("which mode should I use for a two person meeting"))
        #expect(QuestionDetector.isQuestion("should we raise the token cap"))
    }

    @Test("Chinese markers are matched anywhere in the sentence")
    func chineseMarkers() {
        #expect(QuestionDetector.isQuestion("我想知道為什麼字幕會跳動"))
        #expect(QuestionDetector.isQuestion("這兩個模式差別在哪"))
        #expect(QuestionDetector.isQuestion("你建議我用哪一個"))
    }

    /// An instruction that happens to contain a question later is still work to
    /// do. Only a leading interrogative counts in English.
    @Test("an instruction containing a question is still an instruction")
    func midSentenceQuestionsDoNotCount() {
        #expect(!QuestionDetector.isQuestion("fix the parser and tell me what broke"))
        #expect(!QuestionDetector.isQuestion("改成 XML 標籤輸出，不要新增套件"))
        #expect(!QuestionDetector.isQuestion("Add a retry to Sources/Uploader.swift"))
    }

    @Test("blank input is not a question")
    func blankIsNotAQuestion() {
        #expect(!QuestionDetector.isQuestion(""))
        #expect(!QuestionDetector.isQuestion("   "))
    }
}

/// A long request routinely holds several distinct tasks, and a single `goal`
/// sentence could only ever carry the first.
@Suite("Multi-task prompts")
struct PromptStepsTests {

    private func render(_ ir: PromptIR, layout: PromptLayout = .claudeXML) -> String {
        PromptRenderer.render(
            ir, options: PromptRenderOptions(layout: layout, detail: .full)
        ).content
    }

    /// Anthropic's guidance: "provide instructions as sequential steps using
    /// numbered lists ... when the order or completeness of steps matters".
    @Test("several tasks render as a numbered list under the goal")
    func stepsAreNumbered() {
        let content = render(PromptIR(
            goal: "Rewrite the renderer",
            steps: ["Emit XML tags", "Let the user pick claude or codex", "Drop the JSON output"]
        ))
        #expect(content.contains("1. Emit XML tags"))
        #expect(content.contains("2. Let the user pick claude or codex"))
        #expect(content.contains("3. Drop the JSON output"))
        // The goal stays the lead line — not a numbered item, and not bulleted.
        #expect(content.contains("<task>\nRewrite the renderer\n\n1."), "\(content)")
    }

    /// A one-item numbered list reads as an unfinished list, so a single step is
    /// not numbered — but it is still printed.
    ///
    /// It used to be dropped outright, on the reasoning that one step is the goal
    /// restated. That is often true and was never checked, so a step carrying
    /// something the goal did not say was deleted from the prompt. It also became
    /// reachable by another route: hoisting a workflow directive out of a
    /// two-step list leaves exactly one step behind, and that one was real.
    @Test("a single step is printed but not numbered")
    func oneStepIsNotAList() {
        let content = render(PromptIR(goal: "Rewrite the renderer", steps: ["Emit XML tags"]))
        #expect(!content.contains("1."))
        #expect(content.contains("Rewrite the renderer"))
        #expect(content.contains("Emit XML tags"), "\(content)")
    }

    /// The case the old rule was right about.
    @Test("a step that only restates the goal is dropped")
    func aRestatedGoalIsDropped() {
        let content = render(PromptIR(
            goal: "Rewrite the renderer", steps: ["Rewrite the renderer"]
        ))
        #expect(content.contains("<task>Rewrite the renderer</task>"), "\(content)")
    }

    @Test("numbered steps keep their numbers in Markdown too")
    func markdownKeepsTheNumbers() {
        let content = render(
            PromptIR(goal: "Rewrite the renderer", steps: ["Emit XML tags", "Drop the JSON"]),
            layout: .codexMarkdown
        )
        #expect(content.contains("1. Emit XML tags"))
        #expect(!content.contains("- 1."))
    }

    @Test("ordinary bullets still get dashes")
    func bulletsAreUnchanged() {
        // Wording the rulebook does not recognise, so it survives verbatim and
        // the only thing under test is the bullet marker.
        let content = render(PromptIR(
            goal: "Rewrite the renderer",
            constraints: ["Ship before the Friday demo", "Keep the icon 24 points wide"]
        ))
        #expect(content.contains("- Ship before the Friday demo"), "\(content)")
        #expect(!content.contains("1. Ship"))
    }

    @Test("steps are tightened and deduplicated like every other list")
    func stepsAreOptimized() {
        let ir = PromptOptimizer.optimize(PromptIR(
            goal: "Rewrite the renderer",
            steps: ["Please emit XML tags.", "Emit XML tags", "Drop the JSON output"]
        ))
        // "Please " is a hedge prefix, so it is stripped — leaving the two
        // spellings as near-duplicates, which collapse to one.
        #expect(ir.steps.count == 2)
        #expect(ir.steps.last == "Drop the JSON output")
        #expect(ir.steps.first?.lowercased() == "emit xml tags")
    }
}

/// The split between the two levels is one question — did the user say it, or
/// did the compiler add it? — and it was decided by measuring, not by intuition.
/// An earlier three-level version put `out_of_scope` in the always-keep tier and
/// cut `done_when`, which the numbers contradict on both counts.
@Suite("Output detail level")
struct PromptDetailLevelTests {

    private var stated: PromptIR {
        PromptIR(
            goal: "Add a retry",
            context: ["It fails on 5xx"],
            constraints: ["NO_DEPS"],
            scopeExclusions: ["Do not touch the parser"],
            deliverables: ["A retry helper"],
            acceptance: ["Existing tests pass"],
            failureCases: ["Retry storms under load"],
            references: [PromptReference(path: "Sources/Uploader.swift")],
            suggestedTools: ["swift test"]
        )
    }

    private func render(_ ir: PromptIR, _ detail: PromptDetailLevel) -> String {
        PromptRenderer.render(ir, options: PromptRenderOptions(
            symbolMode: .symbolsAssumeRulebook,
            syncedSymbols: Set(PromptStdlib.all.symbols),
            detail: detail
        )).content
    }

    /// The sections that carry what the request said, at the tighter level. Three
    /// of these were cut by an earlier tiering built on intuition; they cost
    /// eleven to twenty-four tokens each and every one is the user's own words.
    @Test("compact keeps what the request said")
    func compactKeepsWhatWasSaid() {
        let content = render(stated, .compact)
        for tag in ["<task>", "<context>", "<output>", "<constraints>",
                    "<done_when>", "<files>"] {
            #expect(content.contains(tag), "\(tag) missing at compact")
        }
    }

    /// …and the three the tool produced are dropped.
    ///
    /// `out_of_scope` is one of them. It is a review boundary — most often the
    /// linter's own default line — and the two levels have to differ by something
    /// a reader can name, which they did not while the only difference was
    /// `risks` and `tools`. A boundary that must survive at `compact` belongs in
    /// `constraints`, which is never gated.
    @Test("compact drops what the tool inferred")
    func compactDropsInferences() {
        let content = render(stated, .compact)
        for tag in ["<risks>", "<tools>", "<out_of_scope>"] {
            #expect(!content.contains(tag), "\(tag) should be withheld at compact")
        }
        let complete = render(stated, .full)
        for tag in ["<risks>", "<tools>", "<out_of_scope>"] {
            #expect(complete.contains(tag), "\(tag) missing at full")
        }
    }

    /// One rule, one place. The level gate used to live in two: a switch that
    /// said `out_of_scope` always printed, plus a content filter that quietly
    /// removed one specific line from it.
    @Test("the linter's boundary and a stated one are gated the same way")
    func exclusionsAreGatedBySectionNotContent() {
        let injected = PromptOptimizer.autoFix(
            PromptIR(goal: "Add a retry", constraints: ["NO_DEPS"])
        ).ir
        #expect(injected.scopeExclusions == [PromptOptimizer.defaultScopeExclusion])
        #expect(!render(injected, .compact).contains("<out_of_scope>"))
        #expect(render(injected, .full).contains("<out_of_scope>"))
        #expect(!render(stated, .compact).contains("<out_of_scope>"))
        #expect(render(stated, .full).contains("<out_of_scope>"))
    }

    /// Symbols are counted on the sections that survive, not on the IR that went
    /// in. A symbol living only inside a dropped section used to inflate
    /// `usedSymbols`, put an unresolvable entry in the legend, drive the sync
    /// hint, and downgrade the whole prompt to the written-out mode.
    @Test("symbols come from the sections that are printed")
    func symbolsFollowTheVisibleSections() {
        let ir = PromptIR(goal: "Refactor uploadChunk", failureCases: ["NO_DEPS"])
        let artifact = PromptRenderer.render(ir, options: PromptRenderOptions(
            symbolMode: .symbolsAssumeRulebook,
            syncedSymbols: Set(PromptStdlib.all.symbols),
            detail: .compact
        ))
        #expect(!artifact.content.contains("NO_DEPS"))
        #expect(!artifact.usedSymbols.contains("NO_DEPS"))
        #expect(!artifact.unresolvedSymbols.contains("NO_DEPS"))
    }

    /// `files` stays at compact for a different reason from the rest: not
    /// importance but verifiability. Every path in it has already been checked
    /// against the request text, so unlike `out_of_scope` it cannot carry
    /// something the user did not say.
    @Test("files stays because its content is verified against the request")
    func filesAreGroundedNotInferred() {
        let invented = PromptOptimizer.optimize(
            PromptIR(goal: "Add a retry",
                     references: [PromptReference(path: "Sources/Uploader.swift")]),
            request: "add a retry, it keeps failing"
        )
        #expect(invented.references.isEmpty)

        let named = PromptOptimizer.optimize(
            PromptIR(goal: "Add a retry",
                     references: [PromptReference(path: "Sources/Uploader.swift")]),
            request: "add a retry to Sources/Uploader.swift"
        )
        #expect(render(named, .compact).contains("<files>"))
    }

    @Test("compact is materially cheaper")
    func compactIsCheaper() {
        let compact = TokenEstimator.estimate(render(stated, .compact))
        let full = TokenEstimator.estimate(render(stated, .full))
        #expect(compact < full)
    }

    /// The legend defines the symbols the surviving sections use, so dropping it
    /// would leave identifiers nothing resolves.
    @Test("the symbol legend is never dropped")
    func legendSurvivesEveryLevel() {
        for detail in PromptDetailLevel.allCases {
            let content = PromptRenderer.render(stated, options: PromptRenderOptions(
                symbolMode: .symbolsWithLegend, detail: detail
            )).content
            #expect(content.contains("<rules>"), "\(detail)")
        }
    }

    /// A question's answer-first block is what makes it a question at all, and
    /// its `done_when` is the success criteria for the answer.
    @Test("a question keeps its shape at every level")
    func questionShapeSurvivesEveryLevel() {
        for detail in PromptDetailLevel.allCases {
            let content = PromptRenderer.render(
                PromptIR(question: "Which mode should I use?",
                         acceptance: ["Names the trade-off"]),
                options: PromptRenderOptions(detail: detail)
            ).content
            #expect(content.contains("<question>"), "\(detail)")
            #expect(content.contains("<answer_first>"), "\(detail)")
            #expect(content.contains("<done_when>"), "\(detail)")
        }
    }
}

/// The question is copied from the user's own words, which is exactly where
/// "CRITICAL:" and "think step by step" come from. It is linted like the goal,
/// and protected like the goal — deleting it would leave a prompt that asks
/// nothing.
@Suite("Questions are linted")
struct QuestionLintTests {

    @Test("flagged wording in a question is found and stripped")
    func questionsAreLinted() {
        let ir = PromptIR(question: "CRITICAL: why does the caption flicker?")
        let findings = PromptOptimizer.lint(ir)
        #expect(findings.contains { $0.rule == .aggressiveEmphasis })

        let fixed = PromptOptimizer.autoFix(ir).ir
        #expect(!fixed.question.contains("CRITICAL:"))
        #expect(fixed.question.contains("why does the caption flicker"))
    }

    /// A question made entirely of flagged wording must not vanish.
    @Test("a question is never emptied by a fix")
    func questionSurvivesAFullStrip() {
        let ir = PromptIR(question: "think step by step")
        let fixed = PromptOptimizer.autoFix(ir).ir
        #expect(!fixed.question.isEmpty)
    }

    /// Spoken politeness is padding; the words being asked about are not.
    @Test("optimize trims the hedge but keeps the question mark")
    func optimizeKeepsTheQuestion() {
        let ir = PromptOptimizer.optimize(
            PromptIR(question: "可不可以幫我看一下這個為什麼會跳動？")
        )
        #expect(ir.question.hasSuffix("？"))
        #expect(ir.question.contains("為什麼會跳動"))
        #expect(!ir.question.hasPrefix("可不可以幫我"))
    }

    @Test("the question is measured with the rest of the prompt")
    func questionCountsAsContent() {
        let ir = PromptIR(question: "Where do the files go?")
        #expect(ir.allBullets.contains("Where do the files go?"))
        #expect(ir.isActionable)
    }
}

/// The question mark is the one signal dictation reliably loses, so the Chinese
/// fallback carries the weight — and it was a hand-written list that named seven
/// A-not-A forms and none of the 怎麼/如何 family in its modal shape. A question
/// that slips through is compiled as a task, which is not a worse answer but the
/// opposite one: the agent goes and builds something instead of replying.
@Suite("Spoken Chinese questions without a question mark")
struct SpokenChineseQuestionTests {

    /// The A-not-A family is recognised structurally by `ChineseQuestionForms`,
    /// so every verb works — not only the seven that used to be listed.
    @Test(arguments: [
        "口述快捷鍵要怎麼關掉", "這個該怎麼修", "該如何設定專案資料夾",
        "字幕框為什麼一直在動", "規則本的 question 跟 task 有什麼差別",
        "我們是不是應該改成固定高度", "需不需要重新下載模型",
        "會不會影響字幕", "這樣算不算 bug", "要用哪些檔案",
    ])
    func spokenQuestionsAreDetected(_ text: String) {
        #expect(QuestionDetector.isQuestion(text), "\(text)")
    }

    /// And the instructions they are easy to confuse with are not.
    ///
    /// Bare 如何 / 是否 / 多少 / 怎麼 are deliberately absent from the marker list
    /// for exactly these: "說明如何安裝" and "檢查是否正確" are work to do.
    @Test(arguments: [
        "把字幕框改成固定高度", "說明如何安裝這個 app", "檢查規則本是否正確",
        "看看怎麼改比較好的地方都列出來", "改成 XML 標籤輸出",
        "不要動 public API", "列出有多少個檔案要改",
    ])
    func instructionsAreNotMistakenForQuestions(_ text: String) {
        #expect(!QuestionDetector.isQuestion(text), "\(text)")
    }

    /// End to end: a spoken question with no question mark reaches the renderer
    /// under `<question>`, not `<task>`.
    @Test func aSpokenQuestionRendersUnderTheQuestionTag() {
        let spoken = "口述快捷鍵要怎麼關掉"
        let ir = PromptIRParser.classifying(
            PromptIRParser.salvage(from: spoken), from: spoken)
        let content = PromptRenderer.render(
            ir, options: PromptRenderOptions(language: .traditionalChinese, detail: .compact)
        ).content
        #expect(content.contains("<question>"), "\(content)")
        #expect(!content.contains("<task>"), "\(content)")
    }
}
