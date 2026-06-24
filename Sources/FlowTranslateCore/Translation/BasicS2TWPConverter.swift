import Foundation

/// Lightweight Simplified → Traditional Chinese converter with a small set of
/// Taiwan-preferred phrase substitutions (an `s2twp`-style fallback).
///
/// This is intentionally dependency-free and covers only common terms; it is a
/// fallback for offline/edge cases. In the App the primary path uses Apple's
/// on-device Translation framework, which already targets `zh-Hant` directly.
/// A full OpenCC dictionary can be dropped in later behind the same protocol.
public struct BasicS2TWPConverter: SimplifiedToTraditionalConverting {
    public init() {}

    public func s2twp(_ text: String) -> String {
        var result = text
        // Phrase-level substitutions first (Taiwan vocabulary), longest matches.
        for (simplified, traditional) in Self.phrases {
            result = result.replacingOccurrences(of: simplified, with: traditional)
        }
        // Then character-level mapping for anything left.
        var out = String()
        out.reserveCapacity(result.count)
        for ch in result {
            out.append(Self.characters[ch].map(String.init) ?? String(ch))
        }
        return out
    }

    /// Common Taiwan-preferred phrase substitutions.
    static let phrases: [(String, String)] = [
        ("软件", "軟體"),
        ("硬件", "硬體"),
        ("网络", "網路"),
        ("服务器", "伺服器"),
        ("内存", "記憶體"),
        ("硬盘", "硬碟"),
        ("鼠标", "滑鼠"),
        ("屏幕", "螢幕"),
        ("视频", "影片"),
        ("程序", "程式"),
        ("打印", "列印"),
        ("信息", "資訊"),
        ("数据", "資料"),
        ("默认", "預設"),
        ("文件", "檔案"),
    ]

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
