import Foundation
import NaturalLanguage

/// How hard a given part of a prompt may be compressed.
///
/// The distinction matters because the parts of a prompt are not equally
/// forgiving. A rambling background paragraph can lose half its words and still
/// say the same thing; a constraint cannot lose a single one. Applying one
/// setting to a whole prompt forces a choice between "barely compressed" and
/// "quietly corrupted".
public enum CompressionLevel: String, Sendable, CaseIterable {
    /// Returned byte-for-byte. Paths, schemas, examples, rule legends.
    case protected
    /// Only transformations that cannot change meaning: filler removal,
    /// contractions, whitespace. Constraints and acceptance criteria.
    case careful
    /// Everything the profile enables, including pruning. Task and context.
    case free
}

/// Which of the eleven techniques are switched on.
///
/// Modelled on `shaminchokshi/less-tokens` (MIT), which enumerates the same
/// eleven and — importantly — reaches the same conclusion about what must never
/// be touched. The word lists below are adapted from it.
public struct CompressionProfile: Sendable, Equatable {
    public var removeFillerPhrases: Bool
    public var applyAbbreviations: Bool
    public var applyContractions: Bool
    public var removeFillerWords: Bool
    public var removeStopwords: Bool
    public var removeFunctionWords: Bool
    /// Keep only content words (nouns/verbs/adjectives/numerals/wh/negations).
    public var posKeepOnly: Bool
    public var lemmatize: Bool
    public var shortenSynonyms: Bool
    /// Protect person/place/organization spans from pruning. Default on.
    public var preserveNamedEntities: Bool
    public var normalizeWhitespace: Bool

    public init(
        removeFillerPhrases: Bool = false,
        applyAbbreviations: Bool = false,
        applyContractions: Bool = false,
        removeFillerWords: Bool = false,
        removeStopwords: Bool = false,
        removeFunctionWords: Bool = false,
        posKeepOnly: Bool = false,
        lemmatize: Bool = false,
        shortenSynonyms: Bool = false,
        preserveNamedEntities: Bool = true,
        normalizeWhitespace: Bool = true
    ) {
        self.removeFillerPhrases = removeFillerPhrases
        self.applyAbbreviations = applyAbbreviations
        self.applyContractions = applyContractions
        self.removeFillerWords = removeFillerWords
        self.removeStopwords = removeStopwords
        self.removeFunctionWords = removeFunctionWords
        self.posKeepOnly = posKeepOnly
        self.lemmatize = lemmatize
        self.shortenSynonyms = shortenSynonyms
        self.preserveNamedEntities = preserveNamedEntities
        self.normalizeWhitespace = normalizeWhitespace
    }

    /// **The profile.** Prunes articles and auxiliaries but keeps the sentence
    /// readable, so a human can still review the prompt. Roughly −35%.
    ///
    /// The only one, now. There were three — conservative (−15%), this, and an
    /// aggressive one — chosen by a segmented control in Settings. Neither
    /// neighbour earned its place: conservative left tokens on the table for no
    /// benefit a user could point at, and aggressive differed from this by
    /// `lemmatize` alone, which is a few per cent for prose a human can no longer
    /// comfortably review. A setting whose options are "slightly worse" and
    /// "slightly riskier" is a decision handed to the user because the author did
    /// not want to make it.
    ///
    /// `posKeepOnly` is deliberately not enabled, though pruning by
    /// part-of-speech is the obvious next step. The analysis of LLMLingua-2's
    /// behaviour in arXiv 2505.00019 found that the part-of-speech distribution
    /// of the tokens it prunes closely follows the distribution of the original
    /// text — the state of the art does not prune by grammatical category, and
    /// building a profile around doing exactly that would be copying the
    /// intuition the evidence contradicts. The technique stays implemented and
    /// tested for anyone constructing a custom profile.
    public static let balanced = CompressionProfile(
        removeFillerPhrases: true, applyAbbreviations: true, applyContractions: true,
        removeFillerWords: true, removeStopwords: true, removeFunctionWords: true,
        shortenSynonyms: true
    )

    /// The subset that is safe at `careful` — nothing that removes a word
    /// carrying meaning.
    var carefulSubset: CompressionProfile {
        CompressionProfile(
            removeFillerPhrases: removeFillerPhrases,
            applyAbbreviations: applyAbbreviations,
            applyContractions: applyContractions,
            removeFillerWords: removeFillerWords,
            preserveNamedEntities: true,
            normalizeWhitespace: normalizeWhitespace
        )
    }
}

/// Deterministic, training-free lexical compression.
///
/// Eleven techniques, applied in a fixed order so a later stage never undoes an
/// earlier one. No model, no network, no dependency: part-of-speech tagging,
/// lemmatization and named-entity recognition come from Apple's
/// `NaturalLanguage` framework rather than NLTK.
///
/// **English only for the pruning stages.** Measured on this machine, `NLTagger`
/// returns `OtherWord` for every Chinese token and offers no lemma or name type,
/// so techniques 5–10 cannot be applied safely to Chinese and are skipped rather
/// than guessed at. This is not a real limitation in practice: the compiled
/// prompt defaults to English precisely because it is cheaper, so the pruning
/// runs on the English IR. Chinese output gets the `careful` techniques only.
public enum LexicalCompressor {

    // MARK: - Protected vocabulary
    //
    // Removing any of these changes what was asked for. They survive every
    // profile, including `aggressive`.

    /// Dropping a negation inverts the instruction. "Do not run this" becoming
    /// "Do run this" is the single worst thing a compressor can do.
    public static let negations: Set<String> = [
        "not", "no", "nor", "never", "neither", "n't", "nothing", "nobody",
        "nowhere", "none", "without", "cannot", "cant", "dont", "doesnt",
        "wont", "shouldnt", "wouldnt", "couldnt", "isnt", "arent", "wasnt",
    ]

    /// Question words carry the intent of a query.
    public static let whWords: Set<String> = [
        "what", "when", "where", "which", "who", "whom", "whose", "why", "how",
    ]

    // MARK: - Word lists (adapted from less-tokens, MIT)

    static let fillerPhrases: [String] = [
        "i was wondering if you could", "i would like to know", "i would like you to",
        "could you please", "can you please", "would you mind",
        "if it is not too much trouble", "if it's not too much trouble",
        "if you don't mind", "if you dont mind", "please kindly", "kindly please",
        "i would appreciate it if you could", "please help me to understand",
        "please help me understand", "can you help me", "i want you to",
        "it is important to", "it's important to", "make sure that you",
        "i need you to", "what i want is", "the thing is",
    ]

    /// Fixed phrases with a shorter equivalent that means the same thing.
    ///
    /// Everything mapping to `re:` is gone, along with `"that is" → "i.e."`.
    /// All were far more often ordinary syntax than the gloss they were mapped
    /// to: `"That is the only file that is safe to edit"` came out as
    /// `"I.e. the only file i.e. safe to edit"`, and `"In terms of latency, do
    /// not exceed 200 ms"` became `"Re: latency, …"` — a subject line, not a
    /// constraint. Both fired at `careful`, on constraints. A rewrite that is
    /// right most of the time is not good enough for a section that cannot lose
    /// a word.
    static let abbreviations: [String: String] = [
        "for example": "e.g.", "for instance": "e.g.",
        "and so on": "etc.", "and so forth": "etc.", "in other words": "i.e.",
        "as soon as possible": "asap", "et cetera": "etc.",
        "in order to": "to", "due to the fact that": "because",
        "at this point in time": "now", "in the event that": "if",
        "a large number of": "many", "the majority of": "most",
    ]

    static let contractions: [String: String] = [
        "do not": "don't", "does not": "doesn't", "did not": "didn't",
        "is not": "isn't", "are not": "aren't", "was not": "wasn't",
        "were not": "weren't", "could not": "couldn't", "would not": "wouldn't",
        "should not": "shouldn't", "will not": "won't", "have not": "haven't",
        "has not": "hasn't", "had not": "hadn't", "it is": "it's",
        "that is": "that's", "there is": "there's", "let us": "let's",
        "they are": "they're", "we are": "we're", "you are": "you're",
    ]

    /// Contractions English does not allow at the end of a clause.
    ///
    /// A copula cannot be contracted when nothing follows it: "leave it exactly
    /// as it is" is not "as it's", and "yes, it is" is not "yes, it's". The
    /// negatives are unaffected — "I don't." is fine — so only the copular forms
    /// are listed.
    ///
    /// The rulebook's own wording hits it: without this list `MIN_DIFF` renders
    /// as "Leave untouched code exactly as it's", in the output the whole feature
    /// exists to produce.
    static let strandedUnsafe: Set<String> = [
        "it is", "that is", "there is", "they are", "we are", "you are",
    ]

    static let fillerWords: Set<String> = [
        "basically", "actually", "really", "just", "somewhat", "perhaps",
        "maybe", "literally", "obviously", "essentially", "definitely",
        "absolutely", "honestly", "frankly", "simply", "merely", "quite",
        "rather", "very", "extremely", "totally", "certainly", "probably",
    ]

    /// Articles and auxiliaries. Never includes anything in `negations`.
    ///
    /// `a` and `an` are deliberately **absent**, though every generic stopword
    /// list contains them. An Empirical Study on Prompt Compression
    /// (arXiv 2505.00019) measured the removals individually and found that
    /// dropping `the` costs almost nothing while dropping `a` *hurts* accuracy —
    /// despite carrying no more information. The authors' proposed explanation
    /// is that low-information tokens act as registers for the model's
    /// intermediate computation, the way register tokens do in Vision
    /// Transformers. Whatever the mechanism, the measurement is the measurement,
    /// and "it looks useless" is not evidence that removing it is free.
    static let functionWords: Set<String> = [
        "the", "is", "am", "are", "was", "were", "be", "been",
        "being", "have", "has", "had", "do", "does", "did", "will", "would",
        "shall", "may", "might", "must", "can", "could", "should",
    ]

    /// Common English stopwords minus everything protected. Kept explicit
    /// rather than pulled from a corpus so the set is auditable and stable.
    static let stopwords: Set<String> = [
        "i", "me", "my", "we", "our", "you", "your", "he", "him", "his", "she",
        "her", "it", "its", "they", "them", "their", "this", "that", "these",
        "those", "and", "but", "or", "if", "because", "as", "until", "while",
        "of", "at", "by", "for", "with", "about", "against", "between", "into",
        "through", "during", "to", "from", "up", "down", "in", "out", "on",
        "off", "over", "under", "again", "then", "once", "here", "there",
        "all", "any", "both", "each", "few", "more", "most", "other", "some",
        "such", "only", "own", "same", "so", "than", "too", "s", "t", "will",
    ]

    /// Curated shorter equivalents.
    ///
    /// less-tokens uses WordNet for this; there is no WordNet on Apple
    /// platforms. `NLEmbedding`'s nearest neighbours are deliberately **not**
    /// used as a substitute — embedding neighbours include antonyms, so
    /// "increase" can sit next to "decrease", and a silent swap there would
    /// invert an instruction. A hand-checked table is smaller but honest.
    static let synonyms: [String: String] = [
        "utilize": "use", "utilise": "use", "leverage": "use",
        "approximately": "about", "demonstrate": "show", "implement": "add",
        "additional": "more", "sufficient": "enough", "numerous": "many",
        "obtain": "get", "require": "need", "attempt": "try",
        "commence": "start", "terminate": "stop", "modify": "change",
        "assist": "help", "purchase": "buy", "construct": "build",
        "initiate": "start", "facilitate": "ease", "endeavour": "try",
        "regarding": "about", "concerning": "about", "subsequently": "then",
        "previously": "before", "currently": "now", "immediately": "now",
        "functionality": "features", "methodology": "method",
        "documentation": "docs", "configuration": "config",
        "repository": "repo", "directory": "dir", "parameter": "param",
        "environment": "env", "specification": "spec",
    ]

    // MARK: - Entry point

    /// Compress `text` at the given level.
    public static func compress(
        _ text: String,
        level: CompressionLevel,
        profile: CompressionProfile = .balanced,
        language: PromptOutputLanguage = .english
    ) -> String {
        guard level != .protected else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        // Chinese has no usable POS/lemma/NER here, so anything that prunes by
        // grammatical role is skipped rather than approximated.
        let resolved = language.resolved(for: text)
        let taggingAvailable = resolved != .traditionalChinese && !TokenEstimator.isCJKDominant(text)

        var effective = level == .careful ? profile.carefulSubset : profile

        // Short imperatives are all signal. "Ship it" has one stopword and
        // pruning it yields "Ship" — a real loss for a saving of one token. The
        // floor buys nothing back and prevents that whole class of damage.
        if wordCount(text) < minimumWordsToPrune {
            effective = effective.carefulSubset
        }

        if !taggingAvailable {
            effective.removeStopwords = false
            effective.removeFunctionWords = false
            effective.posKeepOnly = false
            effective.lemmatize = false
            effective.shortenSynonyms = false
        }

        let endedWithQuestion = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        var result = text

        // Order matters: multi-word transforms first, structural cleanup last,
        // so a later stage cannot undo an earlier one.
        if effective.removeFillerPhrases { result = removeFillerPhrases(result) }
        if effective.applyAbbreviations { result = applyPhraseMap(result, abbreviations) }
        if effective.applyContractions {
            result = applyPhraseMap(result, contractions, skippingClauseFinal: strandedUnsafe)
        }
        if effective.removeFillerWords { result = removeWords(result, fillerWords) }
        if effective.removeStopwords { result = prune(result, removing: stopwords, profile: effective) }
        if effective.removeFunctionWords { result = prune(result, removing: functionWords, profile: effective) }
        if effective.posKeepOnly { result = keepContentWords(result, profile: effective) }
        if effective.lemmatize { result = lemmatize(result, profile: effective) }
        if effective.shortenSynonyms { result = applyWordMap(result, synonyms, profile: effective) }
        if effective.normalizeWhitespace { result = normalize(result) }

        // Pruning can strip the question mark; a question that stops looking
        // like one reads as a command.
        if endedWithQuestion, !result.hasSuffix("?") { result += "?" }
        return result.isEmpty ? text : result
    }

    /// Below this many words, only meaning-preserving techniques are applied.
    static let minimumWordsToPrune = 6

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - 1. Filler phrases

    /// Politeness and hedging that a Chinese request is full of and a prompt has
    /// no use for.
    ///
    /// Chinese gets none of the pruning stages — Apple's `NLTagger` returns no
    /// part of speech or lemma for it — so without this layer a Chinese request
    /// was compressed by essentially nothing. These are safe without any
    /// grammatical analysis because each is a fixed courtesy or hedging formula
    /// carrying no instruction: removing 麻煩你 from 麻煩你先量測 changes who is
    /// being polite, not what is being asked.
    ///
    /// Matched as plain substrings. The English list uses `\b` word boundaries,
    /// which never match in Chinese — that alone made this list a no-op when it
    /// was first tried inside the English path.
    ///
    /// Nothing modal or negative is listed. 不要 / 別 / 勿 / 必須 / 一定 change
    /// what is being asked and are as protected here as `not` is in English.
    ///
    /// Every entry is at least two characters. Substring matching has no word
    /// boundaries to respect, so a single character would cut inside real words
    /// — bare 請 would turn 請求 into 求. Where a listed phrase is the prefix of
    /// a longer courtesy (幫我 / 幫我們), the longer form is listed too and
    /// removed first.
    static let chineseFillerPhrases: [String] = [
        // Requests for a favour — the request survives without them.
        "麻煩你幫我", "麻煩幫我", "麻煩你", "拜託你", "請你幫我", "可以幫我",
        "能不能幫我", "可不可以幫我", "有沒有辦法", "不知道可不可以", "不知道能不能",
        "是不是可以", "可不可以", "能不能", "幫我看一下", "幫我們", "幫我", "幫忙",
        "請你", "請幫", "麻煩您", "您可以",
        // Hedging that adds no constraint.
        "我想說", "我是想說", "我在想", "我想問一下", "我想問", "我的意思是",
        "我覺得應該", "我覺得", "老實說", "說實在的", "坦白說", "基本上", "其實",
        "基本上來說", "簡單來說", "大概就是", "差不多就是", "應該說",
        // Spoken discourse markers. Compound forms are listed in full as well
        // as in parts: sorting by length removes 然後就是 first and would leave
        // 然後就是說 as a stranded 說.
        "然後就是說", "然後就是", "就是說", "我跟你說", "你知道嗎", "對不對", "好不好",
        // Softeners on the verb.
        "看一下", "試試看", "一下下",
    ]

    static func removeChineseFillerPhrases(_ text: String) -> String {
        var result = text
        // Repeat until stable rather than making one longest-first pass.
        //
        // These phrases overlap in both directions, so no single ordering is
        // correct: in 請你幫我看一下, longest-first removes 幫我看一下 and leaves
        // 請你, which no longer matches 請你幫我. Each pass only ever deletes, so
        // the text shrinks monotonically and this terminates; the bound is there
        // to make that guarantee independent of the word list.
        let ordered = chineseFillerPhrases.sorted { $0.count > $1.count }
        for _ in 0..<4 {
            let before = result
            for phrase in ordered {
                result = result.replacingOccurrences(of: phrase, with: "")
            }
            if result == before { break }
        }
        // Courtesy removal leaves doubled or leading punctuation behind.
        result = result.replacingOccurrences(
            of: "^[，、。；：\\s]+", with: "", options: .regularExpression
        )
        return result.replacingOccurrences(
            of: "([，、。；：])[，、。；：]+", with: "$1", options: .regularExpression
        )
    }

    static func removeFillerPhrases(_ text: String) -> String {
        var result = text
        if result.contains(where: { TokenEstimator.isCJK($0) }) {
            result = removeChineseFillerPhrases(result)
        }
        // Longest first, so "could you please" is not half-eaten by "could you".
        for phrase in fillerPhrases.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // MARK: - 2, 3. Phrase maps

    static func applyPhraseMap(
        _ text: String,
        _ map: [String: String],
        skippingClauseFinal stranded: Set<String> = []
    ) -> String {
        var result = text
        for (phrase, replacement) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { continue }
            let guarded = stranded.contains(phrase)
            // Rewrite back-to-front so earlier ranges stay valid, and carry the
            // original's capitalization across: "Do not" → "Don't", not "don't".
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                if guarded, isClauseFinal(range.upperBound, in: result) { continue }
                let wasCapitalized = result[range].first?.isUppercase == true
                result.replaceSubrange(
                    range, with: wasCapitalized ? replacement.capitalizedFirst : replacement
                )
            }
        }
        return result
    }

    /// Whether nothing but punctuation follows `index` — the position where a
    /// copula has nothing to lean on and so cannot contract.
    static func isClauseFinal(_ index: String.Index, in text: String) -> Bool {
        var cursor = index
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return true }
        return ".,;:!?)]}\"'".contains(text[cursor])
    }

    // MARK: - 4. Filler words

    static func removeWords(_ text: String, _ words: Set<String>) -> String {
        let spans = codeSpans(in: text) + negationSpans(in: text)
        return rebuild(text) { token, range in
            let key = normalizedKey(token)
            guard words.contains(key), !isProtected(token) else { return token }
            guard !spans.contains(where: { $0.overlaps(range) }) else { return token }
            return nil
        }
    }

    // MARK: - 5, 6. Stopword / function-word pruning

    static func prune(_ text: String, removing words: Set<String>, profile: CompressionProfile) -> String {
        let spans = protectedSpans(in: text, profile: profile)
        return rebuild(text) { token, range in
            let key = normalizedKey(token)
            guard words.contains(key), !isProtected(token) else { return token }
            guard !spans.contains(where: { $0.overlaps(range) }) else { return token }
            return nil
        }
    }

    // MARK: - 7. Content words only

    static func keepContentWords(_ text: String, profile: CompressionProfile) -> String {
        let spans = protectedSpans(in: text, profile: profile)
        let tags = lexicalClasses(in: text)
        let keep: Set<NLTag> = [.noun, .verb, .adjective, .number, .adverb, .otherWord]

        return rebuild(text) { token, range in
            guard !isProtected(token) else { return token }
            guard !spans.contains(where: { $0.overlaps(range) }) else { return token }
            guard let tag = tags[range] else { return token }   // untagged: keep
            return keep.contains(tag) ? token : nil
        }
    }

    // MARK: - 8. Lemmatization

    static func lemmatize(_ text: String, profile: CompressionProfile) -> String {
        let spans = protectedSpans(in: text, profile: profile)
        let lemmas = lemmaMap(in: text)
        return rebuild(text) { token, range in
            guard !isProtected(token) else { return token }
            guard !spans.contains(where: { $0.overlaps(range) }) else { return token }
            guard let lemma = lemmas[range], lemma.count < token.count else { return token }
            return lemma
        }
    }

    // MARK: - 9. Synonyms

    static func applyWordMap(_ text: String, _ map: [String: String], profile: CompressionProfile) -> String {
        let spans = protectedSpans(in: text, profile: profile)
        return rebuild(text) { token, range in
            guard !isProtected(token) else { return token }
            guard !spans.contains(where: { $0.overlaps(range) }) else { return token }
            guard let replacement = map[normalizedKey(token)] else { return token }
            // Preserve a leading capital so sentence starts survive.
            return token.first?.isUppercase == true ? replacement.capitalizedFirst : replacement
        }
    }

    // MARK: - 11. Normalization

    /// Whitespace and punctuation tidying, applied only outside code spans.
    ///
    /// This ran unguarded and was the last stage, after every span-protected
    /// technique — so the protection those stages provide was undone at the very
    /// end. Measured: `../shared/config` → `./shared/config` (a different
    /// directory), `std::string` → `std:string`, `0..<5` → `0.<5`. The
    /// punctuation-collapsing and space-before-punctuation rules cannot tell a
    /// doubled full stop from a range operator, and `normalizeWhitespace` is on
    /// in every profile including `careful`, so this corrupted the sections that
    /// are supposed to be safest.
    static func normalize(_ text: String) -> String {
        // Earliest first, and where two spans start together the WIDER one wins.
        // Several patterns can match at the same offset — `0..<5` is matched
        // both as the version-ish token `0` and as a range — and taking the
        // narrow one left `..<5` outside the protection, which is precisely the
        // text that then got collapsed to `.<5`.
        let protectedRanges = codeSpans(in: text).sorted {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound > $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }

        var result = ""
        var cursor = text.startIndex
        for span in protectedRanges where span.lowerBound >= cursor {
            result += normalizePlain(String(text[cursor..<span.lowerBound]))
            result += text[span]
            cursor = span.upperBound
        }
        result += normalizePlain(String(text[cursor...]))

        // Collapsing runs of spaces is safe everywhere — no identifier this app
        // protects contains a doubled space.
        result = result.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " +\n", with: "\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The punctuation rules, safe only on prose.
    static func normalizePlain(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: " +([,.!?;:])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "([.!?;:,])\\1+", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "[—–]+", with: "-", options: .regularExpression)
        return result
    }

    // MARK: - Protection

    /// Whether a token must survive regardless of profile.
    ///
    /// Beyond negations and wh-words this covers the things a coding prompt
    /// cannot afford to lose: identifiers, paths, flags, versions and units.
    /// less-tokens does not need this category; a prompt about code does.
    static func isProtected(_ token: String) -> Bool {
        let key = normalizedKey(token)
        if negations.contains(key) || whWords.contains(key) { return true }
        if token.contains("/") || token.contains("\\") { return true }   // paths
        if token.contains("_") || token.contains("`") { return true }    // identifiers
        if token.hasPrefix("-") || token.hasPrefix("@") { return true }  // flags, handles
        if token.contains(".") && !token.hasSuffix(".") { return true }  // file.ext, a.b.c
        if token.contains(where: \.isNumber) { return true }             // versions, units
        if token.count > 1, token == token.uppercased(),
           token.contains(where: \.isLetter) { return true }             // SYMBOLS, API
        if isCamelCase(token) { return true }
        if token.contains(where: { TokenEstimator.isCJK($0) }) { return true }
        return false
    }

    static func isCamelCase(_ token: String) -> Bool {
        let letters = Array(token)
        guard letters.count > 1, letters.allSatisfy({ $0.isLetter }) else { return false }
        let hasUpperAfterFirst = letters.dropFirst().contains { $0.isUppercase }
        return hasUpperAfterFirst
    }

    static func normalizedKey(_ token: String) -> String {
        token.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
    }

    // MARK: - NaturalLanguage bridges

    /// Ranges that must survive intact, computed over the whole string.
    ///
    /// Token-level protection is not enough on its own: `NLTagger` splits
    /// `Sources/Uploader.swift` into three word tokens, so nothing that looks
    /// at one token at a time ever sees the slash — and the lemmatizer happily
    /// turned `Sources` into `source`. These patterns match the span first.
    static let codePatterns: [String] = [
        "`[^`]+`",                       // inline code
        "[\\w.@~-]*/[\\w./@~-]+",           // paths, URLs
        "\\b\\w+\\.[A-Za-z]\\w*\\b",             // file.ext, module.member
        "\\b[A-Z][A-Z0-9_]{2,}\\b",          // SYMBOLS, HTTP, API
        "\\b[a-z]+[A-Z]\\w*\\b",             // camelCase
        // PascalCase — every Swift type name. Requires an internal capital so
        // an ordinary sentence-initial word ("Never", "Extract") is not treated
        // as an identifier. Its absence meant `OrderRepository` was invisible to
        // every span-level rule, and a live eval run lost exactly that name.
        "\\b[A-Z][a-z]+[A-Z]\\w*\\b",
        "\\b\\w*_\\w+\\b",                   // snake_case
        "(?<![\\w-])--?[A-Za-z][\\w-]*",      // --flags, -v
        "\\b\\w*\\d[\\w.]*\\b",                // versions, 503, 500ms
        // Qualified names and range operators. Both contain doubled punctuation
        // that the normalizer collapses — `std::string` became `std:string` and
        // `0..<5` became `0.<5` — and neither was matched by any pattern above.
        "\\b\\w+(?:::\\w+)+",                 // std::string, crate::mod::Item
        "\\d+\\s*\\.\\.[<.=]?\\s*\\d+",         // 0..<5, 0...5, 0..5
    ]

    static func codeSpans(in text: String) -> [Range<String.Index>] {
        spans(in: text, matching: codePatterns, caseInsensitive: false)
    }

    static func spans(
        in text: String, matching patterns: [String], caseInsensitive: Bool
    ) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options)
            else { continue }
            let full = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: full) {
                if let range = Range(match.range, in: text) { spans.append(range) }
            }
        }
        return spans
    }

    /// Negations, matched as whole spans rather than tokens.
    ///
    /// `NLTagger` splits `Don't` the Penn-Treebank way, into `Do` + `n't`. Only
    /// the second half is in `negations`, so per-token protection kept `n't` and
    /// pruned `Do` as an auxiliary — turning "Don't change the public API" into
    /// "n't change public API". That is not merely ugly: `n't` is not a word, so
    /// a model reading it is as likely to drop it as to honour it, which makes
    /// the compressor silently capable of inverting an instruction. The whole
    /// contraction is protected as one span, at every profile.
    static let negationPatterns: [String] = [
        "\\b[A-Za-z]+n['\u{2019}]t\\b",                     // don't, can't, isn't
        "\\b(?:do|does|did|is|are|was|were|will|would|"
            + "should|could|can|must|have|has|had)\\s+not\\b",  // do not, will not
        "\\b(?:not|no|never|nor|neither|none|nothing|nobody|nowhere|"
            + "cannot|without)\\b",
    ]

    static func negationSpans(in text: String) -> [Range<String.Index>] {
        spans(in: text, matching: negationPatterns, caseInsensitive: true)
    }

    /// Runs of Latin script inside otherwise-CJK text.
    ///
    /// When someone writes Chinese, the English that survives in the sentence is
    /// not prose — it is a term, an identifier or a quoted error. Pruning it as
    /// though it were English prose turned `index out of range` into
    /// `index range`, silently rewriting the error message the request was
    /// about. There is no general way to tell a quoted string from a phrase, but
    /// in mixed script the odds are lopsided enough to make protection the right
    /// default.
    ///
    /// Applies only to mixed-script text: in an all-English prompt this would
    /// protect the entire input and disable the compressor.
    static func foreignTermSpans(in text: String) -> [Range<String.Index>] {
        guard TokenEstimator.isMixedScript(text) else { return [] }
        return spans(in: text, matching: ["[A-Za-z][A-Za-z0-9 '\u{2019}_./-]*[A-Za-z0-9]"],
                     caseInsensitive: false)
    }

    /// Everything a pruning stage must leave alone.
    ///
    /// Code, negations and foreign terms are unconditional — no compression
    /// profile may trade away an identifier or a prohibition. Named entities are
    /// the only part that varies, because dropping one costs clarity rather than
    /// correctness.
    static func protectedSpans(in text: String, profile: CompressionProfile) -> [Range<String.Index>] {
        var spans = codeSpans(in: text) + negationSpans(in: text) + foreignTermSpans(in: text)
        if profile.preserveNamedEntities { spans += namedEntitySpans(in: text) }
        return spans
    }

    static func namedEntitySpans(in text: String) -> [Range<String.Index>] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var spans: [Range<String.Index>] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if let tag, [NLTag.personalName, .placeName, .organizationName].contains(tag) {
                spans.append(range)
            }
            return true
        }
        return spans
    }

    static func lexicalClasses(in text: String) -> [Range<String.Index>: NLTag] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var map: [Range<String.Index>: NLTag] = [:]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            if let tag { map[range] = tag }
            return true
        }
        return map
    }

    static func lemmaMap(in text: String) -> [Range<String.Index>: String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var map: [Range<String.Index>: String] = [:]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            if let tag, !tag.rawValue.isEmpty { map[range] = tag.rawValue }
            return true
        }
        return map
    }

    // MARK: - Token rebuild

    /// Walk word tokens, letting `transform` keep, replace, or drop each one.
    /// Everything between tokens (spaces, punctuation, newlines) is preserved,
    /// so structure survives even when words are removed.
    static func rebuild(
        _ text: String,
        _ transform: (String, Range<String.Index>) -> String?
    ) -> String {
        var result = ""
        var cursor = text.startIndex

        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .tokenType,
            options: [.omitWhitespace, .omitPunctuation]
        ) { _, range in
            result += text[cursor..<range.lowerBound]
            let token = String(text[range])
            if let kept = transform(token, range) { result += kept }
            cursor = range.upperBound
            return true
        }
        result += text[cursor...]
        return result
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
