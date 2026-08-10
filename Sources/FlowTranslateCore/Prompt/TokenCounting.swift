import Foundation

/// Something that can count tokens in text.
///
/// Exists so `FlowTranslateCore` can report token counts without depending on a
/// tokenizer. The real implementation lives in the app target, where the Qwen
/// model's own BPE tokenizer is already loaded; Core keeps the character
/// heuristic as the fallback and stays dependency-free and fast to test.
public protocol TokenCounting: Sendable {
    /// Token count for `text`, or `nil` when this counter cannot answer right
    /// now — for a model-backed counter, when the model is not loaded.
    func count(_ text: String) -> Int?
}

/// Which counter produced a number, so the UI can label it honestly.
///
/// This distinction is not pedantry. Anthropic does not publish Claude's
/// tokenizer and there is no offline equivalent, so no local counter can report
/// "Claude tokens". Worse, the tokenizer introduced with Claude Opus 4.7
/// produces roughly 30% more tokens than earlier models for the same text, so
/// even a calibrated constant is only correct for one model generation.
/// Presenting any local number as an authoritative Claude count would be
/// telling the user something untrue about their bill.
public enum TokenCountSource: String, Sendable, Equatable {
    /// The local model's real BPE. Exact for what this app itself spends.
    case modelTokenizer
    /// The character-class heuristic. An estimate, and labelled as one.
    case heuristic

    public var isExact: Bool { self == .modelTokenizer }

    /// Short label for the readout.
    public var displayNote: String {
        switch self {
        case .modelTokenizer: return "本機模型實際分詞"
        case .heuristic: return "估算值"
        }
    }
}

/// A count with its provenance attached.
public struct TokenCount: Sendable, Equatable {
    public var value: Int
    public var source: TokenCountSource

    public init(value: Int, source: TokenCountSource) {
        self.value = value
        self.source = source
    }
}

/// Counts tokens with the best available method, falling back cleanly.
///
/// Deliberately not a singleton the whole app reaches into: the counter is
/// injected so tests can run against the heuristic alone and the eval harness
/// can compare the two directly.
public struct TokenMeter: Sendable {
    private let counter: (any TokenCounting)?

    public init(counter: (any TokenCounting)? = nil) {
        self.counter = counter
    }

    public func count(_ text: String) -> TokenCount {
        if let exact = counter?.count(text) {
            return TokenCount(value: exact, source: .modelTokenizer)
        }
        return TokenCount(value: TokenEstimator.estimate(text), source: .heuristic)
    }

    /// Before/after, both measured the same way.
    ///
    /// Measuring the two ends with different counters would produce a saving
    /// that is partly an artifact of the change in method — the one number in
    /// this feature that must never be flattering by accident.
    public func compare(before: String, after: String) -> TokenComparison {
        // Both ends from the same counter, or neither. Relabelling a mixed pair
        // as an estimate was not enough — the *values* were still mixed, so a
        // cached exact "before" against an evicted heuristic "after" could report
        // growth on a prompt that shrank. The cache evicts entries independently,
        // so this is routine rather than exotic.
        guard let exactBefore = counter?.count(before),
              let exactAfter = counter?.count(after)
        else {
            return TokenComparison(
                before: TokenEstimator.estimate(before),
                after: TokenEstimator.estimate(after),
                source: .heuristic
            )
        }
        return TokenComparison(before: exactBefore, after: exactAfter, source: .modelTokenizer)
    }
}
