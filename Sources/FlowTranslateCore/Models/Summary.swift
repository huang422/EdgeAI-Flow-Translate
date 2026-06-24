import Foundation

/// An action item / to-do.
public struct ActionItem: Codable, Sendable, Equatable {
    public var text: String
    public var owner: String?
    public var due: String?

    public init(text: String, owner: String? = nil, due: String? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
    }
}

/// A question/answer pair.
public struct QAPair: Codable, Sendable, Equatable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// A glossary term.
public struct GlossaryTerm: Codable, Sendable, Equatable {
    public var term: String
    public var definition: String

    public init(term: String, definition: String) {
        self.term = term
        self.definition = definition
    }
}

/// Meeting summary (data-model.md: Summary). Produced offline (non real-time).
public struct Summary: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sessionId: UUID
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var qa: [QAPair]
    public var glossary: [GlossaryTerm]
    public var generatedAt: Date
    public var modelName: String

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        overview: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        qa: [QAPair] = [],
        glossary: [GlossaryTerm] = [],
        generatedAt: Date = Date(),
        modelName: String = "qwen3.5-4b-4bit"
    ) {
        self.id = id
        self.sessionId = sessionId
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.qa = qa
        self.glossary = glossary
        self.generatedAt = generatedAt
        self.modelName = modelName
    }
}
