import Foundation

/// Quality safety net for Traditional-Chinese (Taiwan) subtitle output from the
/// on-device LLM translator. Two independent passes:
///
/// 1. **Script guard** — the 4-bit Qwen model occasionally slips into Simplified
///    characters despite the prompt. Leakage is detected with a curated set of
///    high-frequency characters that exist ONLY in Simplified Chinese (so
///    genuine Traditional text can never false-positive), and only then is the
///    whole line converted via `BasicS2TWPConverter` (Taiwan phrases + ICU
///    `Hans-Hant`, which handles one-to-many mappings like 头发→頭髮, 干杯→乾杯).
///    Clean Traditional lines are left byte-for-byte untouched.
/// 2. **Taiwan vocabulary** — always applied: rewrites unambiguous
///    Mainland-only terms that survive in Traditional script (視頻→影片,
///    服務器→伺服器 …). Only terms with no legitimate Taiwan reading are listed.
public enum TraditionalChineseGuard {
    /// Final polish for one translated subtitle line.
    public static func polish(_ text: String) -> String {
        var result = text
        if containsSimplified(result) {
            result = BasicS2TWPConverter().s2twp(result)
        }
        for (mainland, taiwan) in Self.mainlandTraditionalTerms {
            result = result.replacingOccurrences(of: mainland, with: taiwan)
        }
        return result
    }

    /// Whether the text contains Simplified-Chinese leakage. Uses only
    /// characters that are not valid Traditional characters, so Traditional
    /// text (including 里/干/后-style shared characters) never triggers.
    static func containsSimplified(_ text: String) -> Bool {
        text.contains { simplifiedOnly.contains($0) }
    }

    /// High-frequency characters that exist only in Simplified Chinese. Any
    /// Simplified sentence almost surely contains at least one (they include
    /// the most common function words 這/會/說/們/時…).
    static let simplifiedOnly: Set<Character> = [
        "们", "这", "说", "对", "时", "会", "为", "发", "见", "论", "还", "现",
        "点", "让", "关", "开", "问", "间", "电", "视", "计", "认", "识", "记",
        "语", "请", "谈", "议", "从", "与", "网", "络", "结", "给", "统", "经",
        "总", "处", "务", "应", "该", "变", "边", "达", "过", "运", "进", "动",
        "岁", "观", "觉", "听", "讲", "买", "卖", "车", "东", "学", "写", "读",
        "门", "长", "张", "马", "头", "实", "试", "话", "译", "简", "体", "样",
        "没", "么", "国", "个", "产", "业", "区", "员", "队", "决", "确", "题",
    ]

    /// Mainland terms written in Traditional script → Taiwan equivalents.
    /// Deliberately conservative: only terms with no legitimate Taiwan usage
    /// (e.g. 程序/文件/質量 are REAL Taiwan words and must not be rewritten).
    static let mainlandTraditionalTerms: [(String, String)] = [
        ("軟件", "軟體"),
        ("硬件", "硬體"),
        ("網絡", "網路"),
        ("服務器", "伺服器"),
        ("內存", "記憶體"),
        ("硬盤", "硬碟"),
        ("鼠標", "滑鼠"),
        ("屏幕", "螢幕"),
        ("視頻", "影片"),
        ("打印", "列印"),
        ("默認", "預設"),
        ("人工智能", "人工智慧"),
    ]
}
