import Testing
@testable import FlowTranslateCore

@Suite struct TraditionalChineseGuardTests {
    @Test func cleanTraditionalTextIsUntouched() {
        // Shared characters (里/干/后 as part of legit Traditional words) must never
        // trigger the script conversion.
        let text = "我們已經跑了五公里，乾杯之後在裡面討論。"
        #expect(TraditionalChineseGuard.containsSimplified(text) == false)
        #expect(TraditionalChineseGuard.polish(text) == text)
    }

    @Test func detectsAndConvertsSimplifiedLeakage() {
        let leaked = "这个会议的问题很简单"
        #expect(TraditionalChineseGuard.containsSimplified(leaked) == true)
        let polished = TraditionalChineseGuard.polish(leaked)
        #expect(polished == "這個會議的問題很簡單")
    }

    @Test func convertsOneToManyCharactersCorrectly() {
        // ICU handles contextual one-to-many mappings (发→髮/發, 干→乾/幹).
        let polished = TraditionalChineseGuard.polish("她的头发很长，我们发现了问题")
        #expect(polished.contains("頭髮"))
        #expect(polished.contains("發現"))
    }

    @Test func rewritesMainlandTermsInTraditionalScript() {
        // Fully Traditional text with Mainland vocabulary still gets Taiwan terms.
        let polished = TraditionalChineseGuard.polish("請把視頻上傳到服務器，軟件會自動處理。")
        #expect(polished == "請把影片上傳到伺服器，軟體會自動處理。")
    }

    @Test func keepsLegitimateTaiwanWords() {
        // 程序/文件/質量 are real Taiwan words — must NOT be rewritten.
        let text = "依法律程序處理這份文件。"
        #expect(TraditionalChineseGuard.polish(text) == text)
    }

    @Test func simplifiedWithMainlandTermsGetsBothPasses() {
        let polished = TraditionalChineseGuard.polish("这个软件的网络设置有问题")
        #expect(polished == "這個軟體的網路設置有問題")
    }
}
