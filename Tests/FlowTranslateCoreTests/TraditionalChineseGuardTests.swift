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

/// Detecting Simplified characters with ICU instead of a hand-written list.
///
/// The list held 84 characters and was written for translation output, where a
/// whole translated sentence almost always contains one of them. Pointed at short
/// recognizer output — which is what the dictation path does — it missed
/// constantly: 碼, 幫, 謝, 嗎, 氣 were all absent, so "程式码" was never converted.
@Suite struct SimplifiedDetectionTests {

    /// The hand-written list `containsSimplified` used to consult.
    ///
    /// Lives here rather than in the shipping type, which is where it stayed for
    /// a while after being retired: its only reader was this file, and leaving it
    /// on `TraditionalChineseGuard` invited a future caller to reach for the
    /// detector that missed 碼/幫/謝/嗎/氣.
    static let retiredList: Set<Character> = [
        "们", "这", "说", "对", "时", "会", "为", "发", "见", "论", "还", "现",
        "点", "让", "关", "开", "问", "间", "电", "视", "计", "认", "识", "记",
        "语", "请", "谈", "议", "从", "与", "网", "络", "结", "给", "统", "经",
        "总", "处", "务", "应", "该", "变", "边", "达", "过", "运", "进", "动",
        "岁", "观", "觉", "听", "讲", "买", "卖", "车", "东", "学", "写", "读",
        "门", "长", "张", "马", "头", "实", "试", "话", "译", "简", "体", "样",
        "没", "么", "国", "个", "产", "业", "区", "员", "队", "决", "确", "题",
    ]

    /// Everything the old list caught must still be caught.
    @Test func theReplacementIsAStrictImprovement() {
        let missed = Self.retiredList.filter { !TraditionalChineseGuard.isSimplifiedOnly($0) }
        #expect(missed.isEmpty, "\(missed.sorted())")
    }

    /// And the characters it missed are caught now.
    @Test(arguments: ["码", "帮", "谢", "吗", "气", "脑", "网", "机", "开", "关"])
    func charactersTheListMissedAreDetected(_ character: Character) {
        #expect(TraditionalChineseGuard.isSimplifiedOnly(character))
    }

    /// Traditional characters, and the ones valid in both scripts, must not
    /// trigger — a false positive rewrites correct text.
    ///
    /// The second row is the one ICU gets wrong on its own: `Hans-Hant` is a
    /// conversion table, so it rewrites 干→乾, 后→後, 舍→捨, 于→於 even though
    /// every one of those is a perfectly ordinary Traditional character.
    @Test(arguments: ["程", "式", "碼", "幫", "謝", "嗎", "氣",
                      "裡", "後", "乾", "麵", "隻", "採", "係", "台", "臺",
                      "干", "后", "舍", "于", "杰", "范", "斗", "厘", "云", "几"])
    func traditionalAndSharedCharactersDoNotTrigger(_ character: Character) {
        #expect(!TraditionalChineseGuard.isSimplifiedOnly(character))
    }

    /// The corruption those false positives caused, end to end.
    @Test(arguments: ["這個訊號有干擾", "他不想干預這件事", "他住在學校宿舍",
                      "范先生和杰倫都到了", "誤差只有一公厘"])
    func cleanTraditionalSentencesAreNotRewritten(_ sentence: String) {
        #expect(!TraditionalChineseGuard.containsSimplified(sentence))
        #expect(TraditionalChineseGuard.normalizingScript(sentence) == sentence)
        #expect(TraditionalChineseGuard.polish(sentence) == sentence)
    }

    /// Excluding them from *detection* costs nothing in *conversion*: a genuinely
    /// Simplified sentence still trips on its other characters, and the
    /// whole-string transform then resolves the shared ones from context.
    @Test func sharedCharactersAreStillConvertedInSimplifiedText() {
        #expect(TraditionalChineseGuard.normalizingScript("这个房间很干净") == "這個房間很乾淨")
        #expect(TraditionalChineseGuard.normalizingScript("这是我们以后的计划") == "這是我們以後的計劃")
    }

    /// Dictation is a record of what was said, so the script may change and the
    /// **words** may not. `polish` is the translation path and does both.
    @Test func normalizingScriptLeavesVocabularyAlone() {
        #expect(TraditionalChineseGuard.normalizingScript("这个视频很好") == "這個視頻很好")
        #expect(TraditionalChineseGuard.normalizingScript("我看了数据") == "我看了數據")
        #expect(TraditionalChineseGuard.polish("这个视频很好") == "這個影片很好")
    }

    @Test func latinAndDigitsAreNotHan() {
        for character in "abc123 .,!" {
            #expect(!TraditionalChineseGuard.isSimplifiedOnly(character))
        }
    }

    /// The case from the field: a short dictated phrase the old list let through.
    @Test func aShortSimplifiedPhraseIsConverted() {
        #expect(TraditionalChineseGuard.normalizingScript("程式码") == "程式碼")
        #expect(TraditionalChineseGuard.normalizingScript("帮我看一下") == "幫我看一下")
        #expect(TraditionalChineseGuard.normalizingScript("可以吗") == "可以嗎")
    }

    /// Traditional input comes back byte-for-byte.
    @Test func traditionalTextIsUntouched() {
        let text = "幫我在 Sources/Uploader.swift 加上重試機制，測試要過。"
        #expect(TraditionalChineseGuard.normalizingScript(text) == text)
    }

}
