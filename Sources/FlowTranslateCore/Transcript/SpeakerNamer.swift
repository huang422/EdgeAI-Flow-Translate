import Foundation

/// A generated name for a diarized speaker.
///
/// Two forms, because the two places a speaker name appears have very different
/// amounts of room. The floating caption band reserves a fixed column on every
/// row — including rows that have no label yet — so a wide column is a permanent
/// tax on the caption text beside it. The transcript window and the export have
/// space to spare.
public struct SpeakerName: Sendable, Equatable, Hashable {
    /// The model half — `Claude`, `Qwen`.
    public let model: String
    /// The fruit half — `Mango`, `Peach`.
    public let fruit: String
    /// Whether `model` alone identifies this speaker in this session. True for
    /// the first ten, who are drawn without replacement; false afterwards, once
    /// the pools have to start repeating.
    public let modelIsUnique: Bool

    public init(model: String, fruit: String, modelIsUnique: Bool = true) {
        self.model = model
        self.fruit = fruit
        self.modelIsUnique = modelIsUnique
    }

    /// `Claude Mango`. Used in the transcript, the summary and the export.
    public var full: String { "\(model) \(fruit)" }

    /// The model half alone: `Claude`, or the whole `Speaker 11` past the pools.
    ///
    /// No longer what either speaker column renders — both stack the two halves
    /// instead, which costs less width (54 pt against 61 at the default size) and
    /// keeps the whole name. Kept because "the identifying half" is a real thing
    /// to ask a name for, and because `modelIsUnique` is the property that makes
    /// drawing without replacement worth doing.
    public var short: String { modelIsUnique ? model : full }

    /// The full name broken at the join: `Claude` above `Mango`.
    ///
    /// Which is how both speaker columns render it. A name in one line has to
    /// reserve its whole width on **every** row of the caption band — including
    /// the rows with no speaker — and the band only has 600 pt of caption to
    /// spend. Two stacked halves need the width of the wider *half*, about 55 pt
    /// instead of 95, and nothing is abbreviated away: `Claude Mango` and
    /// `Claude Peach` stay distinguishable, which showing the model half alone
    /// could not promise once the pools were exhausted.
    public var wrapped: String { Self.wrapping(full) }

    /// The same treatment for a label that arrives as a plain string — a
    /// restored transcript line, an exported record read back in.
    ///
    /// Splits at the **last** space, so `Speaker 11` wraps to `Speaker` above
    /// `11` and a name that somehow contains two spaces still yields two lines.
    public static func wrapping(_ label: String) -> String {
        guard let space = label.lastIndex(of: " ") else { return label }
        return label.replacingCharacters(in: space...space, with: "\n")
    }
}

/// Gives each diarized speaker a memorable name instead of `Speaker 1`.
///
/// A number tells you nothing and reads as an error when the count is wrong; a
/// name is easier to hold in your head across a meeting, and easier to correct
/// afterwards in the transcript.
///
/// **The first ten speakers draw both halves without replacement**, which is
/// stricter than only avoiding repeated pairs, and deliberately so:
///
/// - The caption band shows the model half alone, so that half has to identify
///   the speaker by itself. `Claude Mango` and `Claude Peach` would both render
///   as `Claude` there.
/// - A pair-unique scheme lets two speakers differ by their second word only,
///   which is exactly the pair a reader skimming a transcript confuses.
///
/// Ten covers any real meeting on one audio source. Past ten the pools are
/// exhausted and numbering resumes — `Speaker 11`, `Speaker 12` — rather than
/// repeating a half. A repeated half is worse than a number here: two speakers
/// both rendering as `Claude` in the band is a name that has stopped naming
/// anything, and by the eleventh distinct voice on one source the diarizer's
/// answer is doubtful anyway, so a plain number is the honest label.
public struct SpeakerNamer: Sendable {

    public static let models = [
        "GPT", "Claude", "Gemini", "Qwen", "Llama",
        "Grok", "Nemotron", "DeepSeek", "Kimi", "GLM",
    ]

    public static let fruits = [
        "Apple", "Banana", "Mango", "Peach", "Grape",
        "Lime", "Kiwi", "Orange", "Berry", "Lemon",
    ]

    /// Assignments made so far, keyed by the diarizer's own speaker identity.
    private var assigned: [String: SpeakerName] = [:]
    private var usedModels: Set<String> = []
    private var usedFruits: Set<String> = []
    /// Injected so a test can assert on an exact sequence. Production draws from
    /// the system generator, so two meetings do not get the same cast.
    private let randomSource: (@Sendable (Int) -> Int)

    public init(randomSource: (@Sendable (Int) -> Int)? = nil) {
        self.randomSource = randomSource ?? { count in Int.random(in: 0..<max(1, count)) }
    }

    /// The name for a diarizer speaker id, minting one on first sight.
    ///
    /// Keyed by the raw identity rather than by order of appearance, so a speaker
    /// who says nothing for ten minutes comes back with the name they had.
    public mutating func name(for speakerID: String) -> SpeakerName {
        let key = speakerID.trimmingCharacters(in: .whitespaces)
        if let existing = assigned[key] { return existing }
        let name = mint()
        assigned[key] = name
        return name
    }

    private mutating func mint() -> SpeakerName {
        // Both halves fresh, while the pools last.
        if let model = pick(Self.models.filter { !usedModels.contains($0) }),
           let fruit = pick(Self.fruits.filter { !usedFruits.contains($0) }) {
            usedModels.insert(model)
            usedFruits.insert(fruit)
            return SpeakerName(model: model, fruit: fruit, modelIsUnique: true)
        }
        // Pools exhausted. Numbered from the running total, so the eleventh
        // speaker is `Speaker 11` and no number is ever handed out twice.
        return SpeakerName(model: "Speaker", fruit: "\(assigned.count + 1)", modelIsUnique: false)
    }

    private func pick(_ available: [String]) -> String? {
        guard !available.isEmpty else { return nil }
        return available[bounded(randomSource(available.count), available.count)]
    }

    /// Clamp an injected index, so a test generator returning something silly
    /// cannot trap.
    private func bounded(_ index: Int, _ count: Int) -> Int {
        min(max(0, index), count - 1)
    }

    /// Forget every assignment. Called when a meeting starts, so each meeting
    /// gets its own cast rather than inheriting the last one's.
    public mutating func reset() {
        assigned = [:]
        usedModels = []
        usedFruits = []
    }

    /// Every full name the generator can produce.
    ///
    /// Exists so the UI can size its fixed-width speaker column by *measuring*
    /// rather than guessing. Character count is not width — `DeepSeek` and
    /// `Nemotron` are both eight characters and `DeepSeek` renders wider — and a
    /// column sized from a guess truncates the labels it exists to show. That
    /// mistake is already documented in `CaptionTheme.speakerSlotWidth`; this
    /// keeps the fix available rather than repeating it.
    public static var allFullNames: [String] {
        models.flatMap { model in fruits.map { "\(model) \($0)" } }
    }

    /// Every short (band) name the generator can produce.
    public static var allShortNames: [String] { models }

    /// Every half a wrapped name can put on one line.
    ///
    /// Exists so a column that stacks the halves can be measured the same way
    /// the one-line column was — by trying every candidate — rather than by
    /// assuming the halves are narrower than the whole and guessing by how much.
    public static var allNameHalves: [String] { models + fruits + ["Speaker", "88"] }
}
