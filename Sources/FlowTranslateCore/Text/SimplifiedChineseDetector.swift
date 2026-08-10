import Foundation

/// Detects Simplified Chinese characters, so output that drifted out of
/// Traditional can be rejected.
///
/// Qwen is trained predominantly on Simplified Chinese and drifts into it
/// whenever an instruction says only "keep the same language" — Simplified and
/// Traditional *are* the same language, so the instruction is satisfied while
/// the output is wrong for a Taiwanese user.
///
/// This **detects only**. It deliberately does not convert: a Simplified →
/// Traditional mapping is lossy in both directions (乾/幹/干 all map to 干, 後/后
/// both to 后), so a converter pass would silently corrupt text that was already
/// correct. Rejecting the repair and keeping the original is the honest
/// alternative — the worst case is a typo that stays a typo, not a sentence
/// rewritten wrongly.
///
/// The table is a representative set of high-frequency Simplified-only forms,
/// not the complete standard. False negatives are acceptable: this catches
/// drift, and drift is never a single character. False positives are not, so
/// every entry has a distinct Traditional counterpart, and characters shared by
/// both scripts (台, 后, 干, 里, 面, 发 as 髮/發 …) are excluded even where a
/// mapping exists.
public enum SimplifiedChineseDetector {

    /// Simplified-only characters. Each has a different Traditional form.
    static let simplifiedOnly: Set<Character> = Set("""
        个们这么应该说试输进设计图时间问题语词义学习数据网络关开发现实电脑软储执编译错误检测优简复杂转\
        换结构类变参调对属继创删读写载显隐选确认续宽颜样页钮标签视频夹径录统线驱备连请响务库询锁释员谢\
        处华汉尔为无与从会东车马鸟鱼龙书长门闻单双严丽举乐乡亚产亲仅价众传伤体则刚剧劝动势医卫厂历压厅\
        县号叶吗园国圆团场坏块坚报头夺奋宁宝宪审层岁岛币师帮带帐广庆庙异弃张归当彻忆态总恋恶惊惧惨愿战\
        扑扩扫扬抢护担拟择挂挥损摆摄敌断晓术机杀权条来杨极枪栏树桥楼欢欧歼残气汤沟洁济浅涛润涨渐湾满滨\
        滚滤灭灯灵炉烂烦热爱牵独狮猎献环疗疯监盘睁码礼祸离种积称稳穷窃竞笔筑粮级纪纯纲纳纸紧组细织终绍\
        经绕绝绩绪维绿缓缘缩罗罚职联声肃肠胜脸腊舰艰艺节苏药荐荣蒋虑虽蚀蝇补装见观规觉览誉订讨让训议记\
        讲论访证评识诉诊诗诚话详诸课谁谈谋谱财责贤败货质贩贪贫购贯费贴贵贷贸贺资赋赌赏赔赚赞赠赢赶趋轨\
        轮轰辆边达迁过运还远迟适逊递逻遗邓邮郑钟钢钥钱铁铜银键镇闭闯闲闷阅阔队阳阶际陆陈险难雾韩顶项顺\
        须预领颗风飞饭饮饱馆驶骂验骗骤鲜鸡鸣鹅麦齐齿龄
        """.filter { !$0.isWhitespace })

    /// Whether the text contains any Simplified-only character.
    public static func containsSimplified(_ text: String) -> Bool {
        text.contains { simplifiedOnly.contains($0) }
    }

    /// The Simplified characters present in `text`.
    public static func simplifiedCharacters(in text: String) -> Set<Character> {
        Set(text.filter { simplifiedOnly.contains($0) })
    }

    /// Whether `corrected` introduced Simplified characters that `original` did
    /// not already have.
    ///
    /// Compared against the original rather than judged absolutely, so a user
    /// who typed or pasted Simplified themselves is not blocked from having
    /// their own text repaired. What is caught is the model *converting* — the
    /// failure this exists for.
    public static func introducesSimplified(original: String, corrected: String) -> Bool {
        !simplifiedCharacters(in: corrected)
            .subtracting(simplifiedCharacters(in: original))
            .isEmpty
    }
}
