import Foundation
import Testing
@testable import FlowTranslateCore

/// Reported from real use: the Tidy pass returned Simplified Chinese.
///
/// The instruction said only "keep the same language", and Simplified *is* the
/// same language — so the model obeyed and the output was still wrong for a
/// Traditional user. Caught here rather than converted, because a Simplified →
/// Traditional mapping is lossy in both directions and would corrupt text that
/// was already right.
@Suite("Simplified Chinese detection")
struct SimplifiedChineseTests {

    @Test("Traditional text is never flagged")
    func traditionalIsClean() {
        let traditional = [
            "幫我在上傳器加上重試機制，不要新增任何套件",
            "這個功能的設計需要重新檢查，測試也要通過",
            "請參考官方文件的建議寫法，選擇適合的模式",
            "編譯錯誤的處理邏輯要改寫，變數命名保持一致",
        ]
        for text in traditional {
            #expect(!SimplifiedChineseDetector.containsSimplified(text), "\(text)")
        }
    }

    @Test("Simplified text is flagged")
    func simplifiedIsCaught() {
        let simplified = [
            "帮我在上传器加上重试机制，不要新增任何套件",
            "这个功能的设计需要重新检查，测试也要通过",
            "请参考官方文档的建议写法，选择适合的模式",
        ]
        for text in simplified {
            #expect(SimplifiedChineseDetector.containsSimplified(text), "\(text)")
        }
    }

    @Test("English and code are never flagged")
    func latinIsClean() {
        #expect(!SimplifiedChineseDetector.containsSimplified(
            "Add retry to Sources/Uploader.swift with maxRetryCount = 3"
        ))
    }

    /// Judged against the original, not absolutely — a user who typed Simplified
    /// themselves still gets their text repaired.
    @Test("only newly introduced Simplified counts as drift")
    func onlyDriftIsRejected() {
        #expect(SimplifiedChineseDetector.introducesSimplified(
            original: "幫我加上重試機制", corrected: "帮我加上重试机制"
        ))
        // Punctuation and spacing fixed, no Simplified character added that the
        // user had not already typed themselves.
        #expect(!SimplifiedChineseDetector.introducesSimplified(
            original: "帮我加上重试机制不要新增套件", corrected: "帮我加上重试机制，不要新增套件。"
        ))
    }

    @Test("the repair gate rejects a Simplified conversion")
    func gateRejectsConversion() {
        #expect(PromptRepairGate.rejection(
            original: "幫我在上傳器加上重試機制，不要新增套件",
            corrected: "帮我在上传器加上重试机制，不要新增套件"
        ) == .simplifiedChinese)
    }

    /// The guard must not block a legitimate Traditional repair.
    @Test("a Traditional repair still passes")
    func traditionalRepairsStillPass() {
        #expect(PromptRepairGate.accepts(
            original: "幫我在上傳器加上重試機制不要新增套件",
            corrected: "幫我在上傳器加上重試機制，不要新增套件。"
        ))
    }
}
