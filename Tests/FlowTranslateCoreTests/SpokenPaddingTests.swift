import Foundation
import Testing
@testable import FlowTranslateCore

/// Measuring verbal padding, and the deletion it licenses.
///
/// The defect these cover: Tidy could not tidy. Only a self-correction cue
/// bought deletion room, so removing the filler that makes up a fifth of ordinary
/// speech blew the budget, `PassageRepairGate` rejected the repair, the fallback
/// returned the original, and the output read exactly as dictated.
@Suite struct SpokenPaddingTests {

    @Test func cleanTextHasNoPadding() {
        #expect(SpokenPadding.estimatedTokens(in: "Add a retry to the uploader.") == 0)
        #expect(SpokenPadding.estimatedTokens(in: "把重試機制加到上傳器。") == 0)
    }

    @Test func englishMarkersAreCounted() {
        let padded = "so basically i think we should you know add a retry"
        #expect(SpokenPadding.estimatedTokens(in: padded) > 0)
    }

    @Test func chineseMarkersAreCounted() {
        let padded = "那個 我想說 就是 我們是不是可以 把重試機制加到上傳器"
        #expect(SpokenPadding.estimatedTokens(in: padded) > 0)
    }

    /// A longer marker is one marker, not also the shorter markers inside it.
    @Test func anOverlappingMarkerIsCountedOnce() {
        let once = SpokenPadding.estimatedTokens(in: "you know what i mean")
        let bare = SpokenPadding.estimatedTokens(in: "you know")
        #expect(once < bare * 3)
    }

    @Test func repeatedWordsCountAsPadding() {
        #expect(SpokenPadding.estimatedTokens(in: "然後然後我們要開始") > 0)
        #expect(SpokenPadding.estimatedTokens(in: "we we should start") > 0)
    }

    /// Reduplication that means something is not padding.
    @Test func singleCharacterReduplicationIsNotPadding() {
        #expect(SpokenPadding.estimatedTokens(in: "你看看那份檔案") == 0)
    }

    /// Demonstratives are not counted, because nothing cheap tells "這個檔案"
    /// (this file) from "這個…這個…" (hesitation), and over-counting inflates the
    /// deletion budget for text that was never padded.
    @Test func demonstrativesAreNotPadding() {
        #expect(SpokenPadding.estimatedTokens(in: "把這個檔案改成那個格式") == 0)
    }

    /// The share the deletion budget is built from, taken from the budget itself
    /// rather than recomputed — one measurement, so the two rules that use it
    /// cannot disagree.
    @Test func theBudgetCarriesTheShare() {
        let budget = PassageRepairGate.DeletionBudget.measured(in: "就是 就是 然後 然後 反正 反正")
        #expect(budget.paddingShare > 0)
        #expect(budget.paddingShare <= 1)
        #expect(PassageRepairGate.DeletionBudget.measured(in: "Add a retry.").paddingShare == 0)
    }

    // MARK: - What the gate now permits

    private func accepts(_ original: String, _ corrected: String) -> Bool {
        PassageRepairGate.accepts(original: original, corrected: corrected)
    }

    @Test("a padded Chinese passage may lose its padding")
    func chineseFillerRemovalIsAccepted() {
        let spoken = "那個 我想說 就是 我們是不是可以 就是 把重試機制加到上傳器 "
            + "然後 timeout 設成 30 秒 然後 就是 重試 3 次"
        let tidied = "我們可以把重試機制加到上傳器，timeout 設成 30 秒，重試 3 次。"
        #expect(accepts(spoken, tidied),
                "\(PassageRepairGate.rejection(original: spoken, corrected: tidied)!)")
    }

    @Test("a padded English passage may lose its padding")
    func englishFillerRemovalIsAccepted() {
        let spoken = "so basically i think we should um kind of add a retry to the "
            + "uploader you know because it sort of fails on 5xx errors i mean"
        let tidied = "We should add a retry to the uploader because it fails on 5xx errors."
        #expect(accepts(spoken, tidied),
                "\(PassageRepairGate.rejection(original: spoken, corrected: tidied)!)")
    }

    /// The budget follows the passage. Clean input still licenses almost nothing,
    /// so the gate is no laxer than it was for text that was not padded.
    @Test("a clean passage still may not be cut down")
    func cleanTextIsStillProtected() {
        let clean = "Add exponential-backoff retry to the uploader. "
            + "It must handle transient 5xx errors and keep the existing tests passing. "
            + "Do not add any new third-party dependencies to the project."
        let gutted = "Add retry to the uploader."
        #expect(!accepts(clean, gutted))
    }

    /// Removing padding is never licence to drop a fact.
    @Test("padding room does not license dropping numbers")
    func numbersStillCannotVanish() {
        let spoken = "就是 那個 timeout 設成 30 秒 然後 重試 3 次 然後 backoff 是 2 倍"
        let lost = "設定 timeout 與重試。"
        #expect(!accepts(spoken, lost))
    }

    @Test("padding room does not license inventing anything")
    func inventionIsStillRejected() {
        let spoken = "就是 那個 我們要 就是 加上重試機制"
        let invented = "我們要加上重試機制，並且改用 AWS S3 儲存。"
        #expect(!accepts(spoken, invented))
    }
}
