import Foundation

/// Zero-latency lookup table for very common short meeting/video utterances
/// (English → Traditional Chinese). When the on-device LLM translator is active,
/// these lines are answered instantly WITHOUT touching the GPU — they neither
/// wait in the translation queue nor delay the sentences behind them.
///
/// Only unambiguous, context-free phrases belong here; anything with real
/// content must go through the model.
public enum InstantPhraseTranslations {
    /// Returns the instant translation for `text`, or nil when the line isn't a
    /// known short phrase (then the caller should use the model).
    public static func lookup(_ text: String, target: SecondCaptionLanguage) -> String? {
        guard target == .traditionalChinese else { return nil }
        return table[normalize(text)]
    }

    /// Lowercase, unify curly apostrophes, collapse whitespace, and strip
    /// surrounding punctuation so "Okay." / "okay!" / " OKAY " all hit the same key.
    static func normalize(_ text: String) -> String {
        let stripSet = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        let words = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: stripSet) }
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    static let table: [String: String] = [
        "yeah": "是的。", "yes": "是的。", "yep": "是的。", "no": "不是。",
        "okay": "好的。", "ok": "好的。", "alright": "好的。", "sure": "當然。",
        "right": "沒錯。", "exactly": "沒錯。", "correct": "正確。",
        "got it": "了解。", "i see": "我明白了。", "makes sense": "有道理。",
        "that makes sense": "有道理。", "sounds good": "聽起來不錯。",
        "thanks": "謝謝。", "thank you": "謝謝。", "thank you so much": "非常感謝。",
        "thanks everyone": "謝謝大家。", "thank you everyone": "謝謝大家。",
        "sorry": "抱歉。", "excuse me": "不好意思。", "no problem": "沒問題。",
        "hello": "哈囉。", "hi": "嗨。", "hi everyone": "大家好。",
        "hello everyone": "大家好。", "good morning": "早安。",
        "good afternoon": "午安。", "good evening": "晚安。",
        "bye": "再見。", "goodbye": "再見。", "see you": "再見。",
        "see you next time": "下次見。", "have a good day": "祝你有美好的一天。",
        "can you hear me": "你們聽得到我的聲音嗎？",
        "can you see my screen": "你們看得到我的畫面嗎？",
        "can everyone see my screen": "大家看得到我的畫面嗎？",
        "let me share my screen": "我來分享我的畫面。",
        "you're muted": "你靜音了。", "you are muted": "你靜音了。",
        "i'm muted": "我剛剛靜音了。",
        "one moment": "稍等一下。", "just a second": "稍等一下。",
        "just a moment": "稍等一下。", "hold on": "稍等一下。",
        "wait a second": "等一下。", "give me a second": "給我一點時間。",
        "any questions": "有任何問題嗎？", "any other questions": "還有其他問題嗎？",
        "does that make sense": "這樣說清楚嗎？",
        "let's get started": "我們開始吧。", "let's begin": "我們開始吧。",
        "let's move on": "我們繼續。", "moving on": "繼續下一項。",
        "next slide please": "請下一張投影片。", "next slide": "下一張投影片。",
        "i'm not sure": "我不確定。", "i don't know": "我不知道。",
        "good question": "好問題。", "that's a good question": "這是個好問題。",
        "that's all": "就這樣。", "that's it": "就這樣。",
        "that's all for today": "今天就到這裡。",
        "welcome back": "歡迎回來。", "welcome everyone": "歡迎大家。",
    ]
}
