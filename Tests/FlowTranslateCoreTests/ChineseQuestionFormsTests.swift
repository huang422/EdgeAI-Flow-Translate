import Foundation
import Testing
@testable import FlowTranslateCore

/// The A-not-A question form, which is built out of a negation and is not one.
///
/// This was blocking Tidy on Chinese entirely: 我們**是不是**可以加上重試 tidied
/// into 我們可以加上重試 looked like a prohibition had been dropped, so the gate
/// threw the repair away and handed back the raw transcript. Asking for something
/// out loud in Chinese routinely uses one of these forms.
@Suite struct ChineseQuestionFormsTests {

    @Test(arguments: ["是不是", "要不要", "可不可以", "有沒有", "行不行", "好不好", "能不能"])
    func aNotAFormsAreDetected(_ form: String) {
        #expect(ChineseQuestionForms.contains(in: "我們\(form)先做這個"))
    }

    @Test func strippingRemovesTheForm() {
        let stripped = ChineseQuestionForms.stripped(from: "我們是不是可以加上重試")
        #expect(!SymbolCompressor.isNegated(stripped), "\(stripped)")
    }

    /// A real prohibition must survive, or the gate stops protecting anything.
    @Test(arguments: ["不要加新的套件", "別動 public API", "不能改這個檔案", "沒有測試不要合併"])
    func realProhibitionsSurvive(_ text: String) {
        #expect(SymbolCompressor.isNegated(ChineseQuestionForms.stripped(from: text)), "\(text)")
    }

    @Test func textWithoutTheFormIsUntouched() {
        let text = "把重試機制加到上傳器"
        #expect(ChineseQuestionForms.stripped(from: text) == text)
        #expect(!ChineseQuestionForms.contains(in: text))
    }

    /// 別 has no A-not-A form, so it is not a pivot — 別…別 is two prohibitions.
    @Test func bieIsNotAPivot() {
        #expect(!ChineseQuestionForms.contains(in: "改別的檔案"))
    }

    // MARK: - What the gates now accept

    /// The precise claim: dropping an A-not-A form is no longer read as losing a
    /// prohibition. Whether the repair is accepted overall is up to the other
    /// rules — a very short passage can still exceed its deletion allowance, and
    /// that is a different, honest answer.
    @Test("dropping an A-not-A form is not a lost prohibition")
    func passageGateDoesNotCallItNegationLost() {
        let spoken = "我們是不是可以把重試機制加到上傳器"
        let tidied = "我們可以把重試機制加到上傳器。"
        #expect(PassageRepairGate.rejection(original: spoken, corrected: tidied) != .negationLost)
    }

    /// With enough passage around it to stay inside the deletion allowance, the
    /// whole repair goes through — which is the case that was failing in use.
    @Test("a dictated Chinese question is tidied when the budget allows")
    func passageGateAcceptsTheRewrite() {
        let spoken = "我們是不是可以就是把重試機制加到上傳器 然後 timeout 設成 30 秒 "
            + "然後 就是 重試 3 次 這樣子"
        let tidied = "我們可以把重試機制加到上傳器，timeout 設成 30 秒，重試 3 次。"
        #expect(PassageRepairGate.accepts(original: spoken, corrected: tidied),
                "\(String(describing: PassageRepairGate.rejection(original: spoken, corrected: tidied)))")
    }

    @Test("the per-sentence gate accepts it too")
    func sentenceGateAcceptsTheRewrite() {
        let spoken = "這個要不要改成 XML 標籤"
        let tidied = "這個要改成 XML 標籤。"
        #expect(PromptRepairGate.rejection(original: spoken, corrected: tidied) == nil)
    }

    /// The rule this must not weaken: a prohibition that disappears is still an
    /// inversion. Same length either side, so nothing else can catch it.
    @Test("losing a real prohibition is still rejected")
    func realInversionIsStillCaught() {
        let spoken = "不要加新的第三方套件，直接用專案現有的相依套件就好"
        let flipped = "可以加新的第三方套件，直接用專案現有的相依套件就好"
        #expect(PassageRepairGate.rejection(original: spoken, corrected: flipped) == .negationLost)
    }
}
