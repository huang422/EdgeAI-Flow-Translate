import Testing
@testable import FlowTranslateCore

@Suite struct PromptOptimizerTests {

    // MARK: - Tightening

    @Test func stripsPolitenessInBothLanguages() {
        #expect(PromptOptimizer.tighten("Please add a retry.") == "add a retry")
        #expect(PromptOptimizer.tighten("Could you add a retry") == "add a retry")
        #expect(PromptOptimizer.tighten("請你幫我加一個 retry。") == "加一個 retry")
        #expect(PromptOptimizer.tighten("我想要你重構這個函式") == "重構這個函式")
    }

    @Test func neverEmptiesABulletThatIsOnlyAHedge() {
        // Stripping down to nothing would silently delete a line the user said.
        #expect(PromptOptimizer.tighten("請") == "請")
        #expect(PromptOptimizer.tighten("please") == "please")
    }

    @Test func keepsQuestionMarksAndEllipses() {
        // A terminal period is free to drop; other terminators change the read.
        #expect(PromptOptimizer.tighten("Which approach is faster?") == "Which approach is faster?")
        #expect(PromptOptimizer.tighten("continue...") == "continue...")
    }

    @Test func relativizesAbsolutePaths() {
        #expect(
            PromptOptimizer.relativizePath("/Users/me/repo/Sources/App.swift", repoRoot: "/Users/me/repo")
                == "Sources/App.swift"
        )
        #expect(PromptOptimizer.relativizePath("./Sources/App.swift", repoRoot: nil) == "Sources/App.swift")
        #expect(PromptOptimizer.relativizePath("Sources/App.swift", repoRoot: "/other") == "Sources/App.swift")
    }

    @Test func dropsRewordedDuplicatesKeepingTheShortest() {
        let kept = PromptOptimizer.deduplicate([
            "Do not add any new dependencies",
            "Do not add new dependencies",
        ])
        #expect(kept == ["Do not add new dependencies"])
    }

    @Test func doesNotTreatOppositesAsDuplicates() {
        // Same words, opposite polarity — collapsing these would silently pick
        // one meaning at random.
        let kept = PromptOptimizer.deduplicate([
            "Use tabs for indentation",
            "Do not use tabs for indentation",
        ])
        #expect(kept.count == 2)
    }

    // MARK: - Lint

    @Test func flagsAggressiveEmphasisAndOffersASoftening() {
        let ir = PromptIR(goal: "Ship it", constraints: ["CRITICAL: always use the search tool"])
        let findings = PromptOptimizer.lint(ir)
        let finding = findings.first { $0.rule == .aggressiveEmphasis }
        #expect(finding != nil)
        #expect(finding?.action == .replaceBullet(
            section: .constraints,
            text: "CRITICAL: always use the search tool",
            with: "always use the search tool"
        ))
    }

    @Test func flagsSelfVerificationRequests() {
        let ir = PromptIR(goal: "Ship it", constraints: ["Double-check your answer before replying"])
        #expect(PromptOptimizer.lint(ir).contains { $0.rule == .selfVerificationRequest })
    }

    @Test func flagsChainOfThoughtRequests() {
        let ir = PromptIR(goal: "Ship it", constraints: ["Think step by step"])
        #expect(PromptOptimizer.lint(ir).contains { $0.rule == .chainOfThoughtRequest })
    }

    @Test func flagsPersonaThatIsNotABehaviourRule() {
        let ir = PromptIR(goal: "Ship it", context: ["You are a senior Swift engineer"])
        #expect(PromptOptimizer.lint(ir).contains { $0.rule == .personaWithoutBehaviour })
    }

    @Test func flagsMissingScopeExclusions() {
        let bare = PromptIR(goal: "Add retry to the uploader")
        #expect(PromptOptimizer.lint(bare).contains { $0.rule == .missingScopeExclusions })

        let bounded = PromptIR(goal: "Add retry", scopeExclusions: ["Do not touch the parser"])
        #expect(PromptOptimizer.lint(bounded).contains { $0.rule == .missingScopeExclusions } == false)
    }

    @Test func flagsUnverifiableAcceptanceAsAdvisoryOnly() {
        let ir = PromptIR(goal: "Ship it", acceptance: ["The result should be high quality"])
        let finding = PromptOptimizer.lint(ir).first { $0.rule == .vagueAcceptance }
        #expect(finding != nil)
        // Nobody but the user can decide what "high quality" means here, so this
        // must never be auto-applied.
        #expect(finding?.isAutoFixable == false)
    }

    @Test func flagsReferencesClaudeCannotLocate() {
        let vague = PromptIR(goal: "Ship it", context: ["Follow the docs"])
        #expect(PromptOptimizer.lint(vague).contains { $0.rule == .unlocatableReference })

        let located = PromptIR(goal: "Ship it", context: ["Follow docs/api.md"])
        #expect(PromptOptimizer.lint(located).contains { $0.rule == .unlocatableReference } == false)
    }

    @Test func flagsContradictoryConstraints() {
        let ir = PromptIR(
            goal: "Ship it",
            constraints: ["Use tabs for indentation", "Do not use tabs for indentation"]
        )
        let finding = PromptOptimizer.lint(ir).first { $0.rule == .contradictoryConstraints }
        #expect(finding != nil)
        #expect(finding?.isAutoFixable == false)
    }

    @Test func flagsDecorativeMarkupButNotOrdinaryProse() {
        let decorated = PromptIR(goal: "Ship it", constraints: ["**Important** keep the API stable"])
        #expect(PromptOptimizer.lint(decorated).contains { $0.rule == .decorativeMarkup })

        // A hedge is not decoration — reporting it here would be wrong, and
        // `optimize` already handles it.
        let plain = PromptIR(goal: "Ship it", constraints: ["Please keep the API stable."])
        #expect(PromptOptimizer.lint(plain).contains { $0.rule == .decorativeMarkup } == false)
    }

    // MARK: - Applying fixes

    @Test func appliesOnlyTheChosenFindings() {
        let ir = PromptIR(
            goal: "Ship it",
            constraints: ["Think step by step", "Keep the API stable"]
        )
        let findings = PromptOptimizer.lint(ir).filter { $0.rule == .chainOfThoughtRequest }
        let fixed = PromptOptimizer.apply(findings, to: ir)
        #expect(fixed.constraints == ["Keep the API stable"])
    }

    @Test func advisoryFindingsChangeNothing() {
        let ir = PromptIR(goal: "Ship it", acceptance: ["The result should be high quality"])
        let findings = PromptOptimizer.lint(ir).filter { $0.rule == .vagueAcceptance }
        #expect(PromptOptimizer.apply(findings, to: ir) == ir)
    }

    @Test func applyingTwiceIsIdempotent() {
        let ir = PromptIR(goal: "Add retry", constraints: ["Double-check your work"])
        let findings = PromptOptimizer.lint(ir)
        let once = PromptOptimizer.apply(findings, to: ir)
        let twice = PromptOptimizer.apply(findings, to: once)
        #expect(once == twice)
    }

    @Test func addingTheDefaultExclusionSatisfiesItsOwnRule() {
        let ir = PromptIR(goal: "Add retry to the uploader")
        let fixed = PromptOptimizer.apply(PromptOptimizer.lint(ir), to: ir)
        #expect(fixed.scopeExclusions == [PromptOptimizer.defaultScopeExclusion])
        #expect(PromptOptimizer.lint(fixed).contains { $0.rule == .missingScopeExclusions } == false)
    }
}

/// The `<files>` section is only worth its tokens if the paths are real.
///
/// A 4B model given two worked examples copies content out of them, so requests
/// that named no file came back citing `Sources/Uploader.swift` — a path from
/// Example 1, in someone else's project. Claude then opens an unrelated file or
/// reports that it does not exist.
@Suite("File references")
struct ReferenceGroundingTests {

    private func optimize(_ paths: [String], request: String) -> [String] {
        let ir = PromptIR(goal: "Do the thing", references: paths.map { PromptReference(path: $0) })
        return PromptOptimizer.optimize(ir, request: request).references.map(\.path)
    }

    @Test("a path the request never named is dropped")
    func inventedPathIsDropped() {
        #expect(optimize(
            ["Sources/Uploader.swift"],
            request: "如果我使用這個方式，檔案要匯出放在哪裡才看得到？"
        ).isEmpty)
    }

    @Test("a path the request named survives")
    func namedPathSurvives() {
        #expect(optimize(
            ["Sources/Uploader.swift"],
            request: "add a retry to Sources/Uploader.swift, it fails on 5xx"
        ) == ["Sources/Uploader.swift"])
    }

    /// Dictation loses separators, and the model legitimately reconstructs the
    /// path from what was heard. Matching the last component keeps that working.
    @Test("a dictated file name still matches its reconstructed path")
    func reconstructedPathSurvives() {
        #expect(optimize(
            ["Sources/Uploader.swift"],
            request: "add a retry to Uploader.swift"
        ) == ["Sources/Uploader.swift"])
        #expect(optimize(
            ["FlowTranslate/UI/CaptureViewModel.swift"],
            request: "CaptureViewModel 裡面的那段要改"
        ) == ["FlowTranslate/UI/CaptureViewModel.swift"])
    }

    /// A two-letter stem matches almost any sentence by accident, which is the
    /// opposite of grounding.
    @Test("a very short stem does not match by accident")
    func shortStemDoesNotMatch() {
        #expect(optimize(["src/io.swift"], request: "make the parser faster").isEmpty)
    }

    /// Without a request there is nothing to check against, and dropping every
    /// reference would be worse than keeping them.
    @Test("no request means no filtering")
    func noRequestKeepsEverything() {
        let ir = PromptIR(goal: "g", references: [PromptReference(path: "a/b.swift")])
        #expect(PromptOptimizer.optimize(ir).references.count == 1)
    }
}
