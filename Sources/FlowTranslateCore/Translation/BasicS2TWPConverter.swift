import Foundation

/// Lightweight Simplified → Traditional Chinese converter with a small set of
/// Taiwan-preferred phrase substitutions (an `s2twp`-style fallback).
///
/// Phrase substitutions (Taiwan vocabulary) run first, then the remaining text
/// is converted with the system ICU `Hans-Hant` transliterator — dependency-free
/// (Foundation) and context-aware for one-to-many characters (头发→頭髮,
/// 干杯→乾杯, 里面→裡面). The small character table remains as a fallback in
/// case the ICU transform is unavailable.
public struct BasicS2TWPConverter {
    public init() {}

    public func s2twp(_ text: String) -> String {
        var result = text
        // Phrase-level substitutions first (Taiwan vocabulary), longest matches.
        for (simplified, traditional) in Self.phrases {
            result = result.replacingOccurrences(of: simplified, with: traditional)
        }
        // Then the ICU script conversion for everything left.
        if let transformed = result.applyingTransform(StringTransform("Hans-Hant"), reverse: false) {
            return transformed
        }
        // Fallback: character-level mapping.
        var out = String()
        out.reserveCapacity(result.count)
        for ch in result {
            out.append(Self.characters[ch].map(String.init) ?? String(ch))
        }
        return out
    }

    /// **Single source of truth** for the Taiwan vocabulary, shared with
    /// `TraditionalChineseGuard` — edit here only, or the two lists drift.
    /// Each entry: the Simplified spelling, the Mainland spelling in Traditional
    /// script (`nil` when a Traditional-script rewrite would be unsafe because
    /// the term is ALSO a legitimate Taiwan word, e.g. 程序/文件), and the
    /// Taiwan-preferred term.
    static let taiwanTerms: [(simplified: String, mainlandTraditional: String?, taiwan: String)] = [
        ("软件", "軟件", "軟體"),
        ("硬件", "硬件", "硬體"),
        ("网络", "網絡", "網路"),
        ("服务器", "服務器", "伺服器"),
        ("内存", "內存", "記憶體"),
        ("硬盘", "硬盤", "硬碟"),
        ("鼠标", "鼠標", "滑鼠"),
        ("屏幕", "屏幕", "螢幕"),
        ("视频", "視頻", "影片"),
        ("打印", "打印", "列印"),
        ("默认", "默認", "預設"),
        ("人工智能", "人工智能", "人工智慧"),
        // Simplified-only rewrites: as Traditional-script words these are real
        // Taiwan vocabulary with a different meaning — never rewrite those.
        ("程序", nil, "程式"),
        ("信息", nil, "資訊"),
        ("数据", nil, "資料"),
        ("文件", nil, "檔案"),
    ]

    /// Simplified → Taiwan phrase substitutions (derived from `taiwanTerms`).
    static let phrases: [(String, String)] = taiwanTerms.map { ($0.simplified, $0.taiwan) }

    /// Common single-character Simplified → Traditional mappings.
    static let characters: [Character: Character] = [
        "这": "這", "个": "個", "们": "們", "国": "國", "时": "時", "后": "後",
        "发": "發", "会": "會", "学": "學", "实": "實", "现": "現", "东": "東",
        "车": "車", "见": "見", "长": "長", "门": "門", "问": "問", "间": "間",
        "关": "關", "开": "開", "应": "應", "当": "當", "该": "該", "说": "說",
        "让": "讓", "对": "對", "还": "還", "进": "進", "过": "過", "么": "麼",
        "没": "沒", "经": "經", "样": "樣", "业": "業", "与": "與", "书": "書",
        "写": "寫", "头": "頭", "务": "務", "动": "動", "区": "區", "医": "醫",
        "双": "雙", "电": "電", "话": "話", "员": "員", "团": "團", "队": "隊",
        "讲": "講", "认": "認", "为": "為", "产": "產", "总": "總", "结": "結",
        "议": "議", "决": "決", "确": "確", "听": "聽", "读": "讀",
    ]
}
