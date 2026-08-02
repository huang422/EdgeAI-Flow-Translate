import Foundation

public struct TimedTextToken: Sendable, Equatable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct SpeakerTurn: Sendable, Equatable {
    public let label: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(label: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.label = label
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct AlignedSpeakerText: Sendable, Equatable {
    public let text: String
    public let speakerLabel: String?
    public let startTime: TimeInterval
    public let endTime: TimeInterval
}

/// Aligns timestamped ASR tokens to diarization turns, splitting text only at
/// measured speaker transitions rather than at ASR chunk boundaries.
public enum SpeakerTurnAligner {
    public static func align(
        tokens: [TimedTextToken], turns: [SpeakerTurn]
    ) -> [AlignedSpeakerText] {
        guard !tokens.isEmpty else { return [] }

        var groups: [(tokens: [TimedTextToken], label: String?)] = []
        var previousLabel: String?
        for token in tokens {
            let label = bestSpeaker(for: token, turns: turns) ?? previousLabel
            // Bind the index rather than testing `groups.last?.label == label`:
            // on an empty `groups` that optional chain yields nil, which compares
            // EQUAL to an unlabelled token — and then indexes groups[-1]. That is
            // the common case, not an exotic one: the first token of an utterance
            // starts with no `previousLabel`, and diarization turns come from a
            // separately buffered audio slice that need not cover it.
            if let lastIndex = groups.indices.last, groups[lastIndex].label == label {
                groups[lastIndex].tokens.append(token)
            } else {
                groups.append(([token], label))
            }
            if label != nil { previousLabel = label }
        }

        return groups.compactMap { group in
            let text = render(group.tokens.map(\.text))
            guard !text.isEmpty, let first = group.tokens.first, let last = group.tokens.last else { return nil }
            return AlignedSpeakerText(
                text: text,
                speakerLabel: group.label,
                startTime: first.startTime,
                endTime: max(first.startTime, last.endTime))
        }
    }

    private static func bestSpeaker(for token: TimedTextToken, turns: [SpeakerTurn]) -> String? {
        var best: (label: String, overlap: TimeInterval)?
        for turn in turns {
            let overlap = max(0, min(token.endTime, turn.endTime) - max(token.startTime, turn.startTime))
            if overlap > (best?.overlap ?? 0) { best = (turn.label, overlap) }
        }
        if let best { return best.label }

        let midpoint = (token.startTime + token.endTime) / 2
        return turns.first { $0.startTime <= midpoint && midpoint <= $0.endTime }?.label
    }

    private static func render(_ pieces: [String]) -> String {
        pieces.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
