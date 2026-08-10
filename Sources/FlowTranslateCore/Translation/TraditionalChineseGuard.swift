import Foundation

/// Quality safety net for Traditional-Chinese (Taiwan) subtitle output from the
/// on-device LLM translator. Two independent passes:
///
/// 1. **Script guard** — the 4-bit Qwen model occasionally slips into Simplified
///    characters despite the prompt. Leakage is detected per character by ICU
///    (`isSimplifiedOnly`), and only then is the whole line converted via
///    `BasicS2TWPConverter` (Taiwan phrases + ICU `Hans-Hant`, which handles
///    one-to-many mappings like 头发→頭髮, 干杯→乾杯). Clean Traditional lines are
///    left byte-for-byte untouched.
/// 2. **Taiwan vocabulary** — always applied: rewrites unambiguous
///    Mainland-only terms that survive in Traditional script (視頻→影片,
///    服務器→伺服器 …). Only terms with no legitimate Taiwan reading are listed.
///
/// `normalizingScript` is the dictation entry point and runs **only** pass 1 —
/// what the speaker said is not translation output, and its vocabulary is not
/// this file's to change.
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

    /// Convert Simplified characters to Traditional and change nothing else.
    ///
    /// The script conversion only, never `polish`'s Taiwan phrase table: this is
    /// the dictation and caption path, where 视频 → 視頻 is correcting a glyph and
    /// 视频 → 影片 would be editing what someone said.
    public static func normalizingScript(_ text: String) -> String {
        guard containsSimplified(text) else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }


    /// Whether the text contains Simplified-Chinese leakage.
    ///
    /// Asks ICU per character rather than consulting a hand-written list: a
    /// character is Simplified-only exactly when the `Hans-Hant` transform
    /// changes it **on its own**, minus the shared characters below.
    ///
    /// The list this replaces held 84 characters and was built for *translation*
    /// output, where a whole translated sentence almost always contains one of
    /// them. Pointed at short recognizer output it missed constantly — including
    /// 碼, 幫, 謝, 嗎 and 氣, so "程式码" was never converted at all. ICU catches
    /// every one of those.
    static func containsSimplified(_ text: String) -> Bool {
        text.contains(where: isSimplifiedOnly)
    }

    /// Characters ICU rewrites that are nonetheless perfectly good Traditional
    /// characters, and so are not evidence of Simplified leakage.
    ///
    /// `Hans-Hant` is a *conversion* table, not a script test, and its
    /// one-to-many entries cover the merges where the Simplified form is itself
    /// a real Traditional character used in another sense: 干 (干擾/若干) maps to
    /// 乾, 后 (皇后) to 後, 舍 (宿舍) to 捨, 于 (于姓) to 於. Asking it "did this
    /// change?" therefore answers yes for text that was already correct — and
    /// the answer is what decides whether the *whole line* is run through the
    /// converter, so 這個訊號有干擾 came back as 乾擾 and 他住在宿舍 as 宿捨.
    /// Nonsense words, in the caption, the transcript and every export.
    ///
    /// Excluding them costs nothing in coverage. A genuinely Simplified sentence
    /// contains other Simplified-only characters — 这, 个, 说, 时 — so it still
    /// triggers, and the conversion that then runs is the context-aware
    /// whole-string transform, which handles 干净→乾淨 and 皇后→皇后 correctly.
    /// This set only decides what counts as *evidence*, never what is converted.
    ///
    /// Derived by running `Hans-Hant` over the characters that are valid in both
    /// scripts and keeping the ones it rewrites; the rest need no entry.
    static let sharedWithTraditional: Set<Character> = [
        "干", "后", "丑", "云", "几", "征", "愿", "斗", "冲", "淀", "杰",
        "夸", "厘", "仆", "舍", "佣", "于", "筑", "范", "丰", "据",
    ]

    /// Cached because this is called per caption line and per dictated sentence,
    /// and the answer for a character never changes. Locked rather than actor-
    /// isolated: the callers are on several different actors and none of them
    /// should have to await a script check.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var simplifiedCache: [Character: Bool] = [:]

    static func isSimplifiedOnly(_ character: Character) -> Bool {
        // Only Han characters can be Simplified; skip the transform for the
        // Latin, digits and punctuation that make up most mixed-script text.
        guard let scalar = character.unicodeScalars.first,
              scalar.value >= 0x3400, scalar.value <= 0x9FFF
        else { return false }
        guard !sharedWithTraditional.contains(character) else { return false }

        cacheLock.lock()
        if let cached = simplifiedCache[character] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let mutable = NSMutableString(string: String(character)) as CFMutableString
        CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
        let changed = (mutable as String) != String(character)

        cacheLock.lock()
        simplifiedCache[character] = changed
        cacheLock.unlock()
        return changed
    }

    /// Mainland terms written in Traditional script → Taiwan equivalents.
    /// Derived from the canonical table in `BasicS2TWPConverter.taiwanTerms`
    /// (single source of truth). Deliberately conservative: entries whose
    /// Traditional spelling is ALSO a real Taiwan word (程序/文件/質量) carry a
    /// `nil` Traditional key there and are excluded here.
    static let mainlandTraditionalTerms: [(String, String)] =
        BasicS2TWPConverter.taiwanTerms.compactMap { term in
            term.mainlandTraditional.map { ($0, term.taiwan) }
        }
}
