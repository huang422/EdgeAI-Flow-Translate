import Foundation

private struct CaptionSpeakerPart: Equatable, Sendable {
    let key: UUID
    let original: String
    let speaker: String?
    var translation: String?
}

/// One line in the floating caption band.
///
/// `id` is the **view identity**: for the current utterance it is minted at the
/// first interim and survives the interim → finalized morph, so the view layer
/// updates the same element in place (no remove/insert jump). `translationKey`
/// is the transcript sentence id used to route translation results.
public struct BandLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// A resumed source gets a new display identity while retaining its ASR id.
    fileprivate var continuedUtterance: UUID?
    public var translationKey: UUID?
    public var english: String
    public var originalRows = OriginalCaptionRows()
    public var chinese: String?
    public var source: AudioSourceType
    public var isFinal: Bool
    fileprivate var rolledUp = false
    public var isOpen: Bool { !isFinal && !rolledUp }
    /// Whether a translation is expected for this line (drives the "⋯" pending
    /// placeholder in the reserved second-line space).
    public var expectsTranslation: Bool
    /// Diarized speaker label ("Speaker 1"…); nil while interim or when
    /// diarization is off.
    public var speakerLabel: String?
    public fileprivate(set) var originalSpeakerLabels: [Int: String] = [:]
    private var speakerParts: [CaptionSpeakerPart] = []

    fileprivate func belongs(to utteranceId: UUID) -> Bool {
        id == utteranceId || continuedUtterance == utteranceId
    }

    public init(
        id: UUID,
        translationKey: UUID? = nil,
        english: String,
        chinese: String? = nil,
        source: AudioSourceType,
        isFinal: Bool,
        expectsTranslation: Bool = false,
        speakerLabel: String? = nil
    ) {
        self.id = id
        self.translationKey = translationKey
        self.english = english
        self.chinese = chinese
        self.source = source
        self.isFinal = isFinal
        self.expectsTranslation = expectsTranslation
        self.speakerLabel = speakerLabel
    }

    fileprivate mutating func addSpeakerPart(
        key: UUID, original: String, speaker: String?, isLast: Bool
    ) {
        speakerParts.append(CaptionSpeakerPart(key: key, original: original, speaker: speaker))
        guard isLast else { return }
        isFinal = true
        // Label rows whose displayed words belong to exactly one recognized
        // speaker. A late boundary inside a read row must not split it again.
        func words(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let parts = speakerParts.map { (words($0.original), $0.speaker) }
        var previous: String?
        for (index, row) in originalRows.rows.enumerated() {
            let text = words(row)
            guard !text.isEmpty else { continue }
            let matching = parts.filter { $0.0.contains(text) }
            guard matching.count == 1, let label = matching.first?.1, label != previous else { continue }
            originalSpeakerLabels[index] = label
            previous = label
        }
        speakerLabel = originalSpeakerLabels[0]
        refreshGroupTranslation()
    }

    fileprivate mutating func receiveGroupTranslation(key: UUID, text: String) -> Bool {
        guard let index = speakerParts.firstIndex(where: { $0.key == key }) else { return false }
        speakerParts[index].translation = text
        refreshGroupTranslation()
        return true
    }

    private mutating func refreshGroupTranslation() {
        let translated = speakerParts.compactMap(\.translation)
        if isFinal, translated.count == speakerParts.count, !translated.isEmpty {
            chinese = translated.joined(separator: "\n")
        }
    }
}

/// Pure state machine for the floating caption band (broadcast "roll-up" model):
///
/// - The **slot** holds the current utterance: it appears with the first interim,
///   morphs **in place** on finalize (same identity → no view jump), and rolls up
///   into `committed` history only when the *next* utterance starts.
/// - Recent finalized lines stay in a bounded buffer. The display selects its
///   configured count from that buffer and the slot.
/// - Pinning freezes a snapshot for reading while counting missed sentences —
///   the `+N` badge — by **commit events**, not array-length diffs (which broke
///   once the buffer was full).
///
/// Value type, no clocks, no UI — fully unit-testable.
public struct CaptionBandState: Equatable, Sendable {
    private var history: [BandLine] = []
    private var recentlyPresented: [AudioSourceType: [UUID]] = [:]
    public var committed: [BandLine] { Array(history.suffix(max(0, historyLimit))) }
    public private(set) var slot: BandLine?

    public private(set) var isPinned = false
    public private(set) var pendingWhilePinned = 0
    private var pinnedCommitted: [BandLine] = []
    private var pinnedSlot: BandLine?

    /// How many finalized lines of history to keep in addition to the slot.
    public var historyLimit: Int

    public init(historyLimit: Int = 1) {
        self.historyLimit = max(0, historyLimit)
    }

    // MARK: - Display

    /// History lines to draw (frozen snapshot while pinned).
    public var visibleCommitted: [BandLine] {
        Array((isPinned ? pinnedCommitted : history).suffix(max(0, historyLimit)))
    }

    /// Fill the selected count with finalized lines when the live slot is absent
    /// or hidden. A settings change takes effect even between ASR events.
    public func visibleLines(showInterim: Bool) -> [BandLine] {
        var lines = isPinned ? pinnedCommitted : history
        if !showInterim { lines.removeAll { !$0.isFinal } }
        if let slot = visibleSlot, slot.isFinal || showInterim {
            lines.append(slot)
        }
        return Array(lines.suffix(displayLimit))
    }

    private var displayLimit: Int { max(0, min(historyLimit, Int.max - 1)) + 1 }
    /// Current-utterance line to draw (frozen snapshot while pinned).
    public var visibleSlot: BandLine? { isPinned ? pinnedSlot : slot }
    /// Whether anything is on screen.
    public var hasContent: Bool { visibleSlot != nil || !(isPinned ? pinnedCommitted : history).isEmpty }
    /// Latest finalized line (for the copy action).
    public var latestFinal: BandLine? {
        if let s = slot, s.isFinal { return s }
        return history.last { $0.isFinal }
    }

    public func line(for id: UUID) -> BandLine? {
        slot?.belongs(to: id) == true ? slot : history.last { $0.belongs(to: id) }
    }

    public func hasPresented(_ id: UUID) -> Bool {
        recentlyPresented.values.contains { $0.contains(id) }
    }

    // MARK: - Events

    /// Live partial for the active utterance. A new `utteranceId` starts a new
    /// utterance. Keep the old slot intact even when its speaker result is
    /// still in flight. A late final updates its metadata in place.
    public mutating func interim(
        utteranceId: UUID,
        source: AudioSourceType,
        english: String,
        chinese: String?,
        expectsTranslation: Bool,
        fitsOriginal: (String) -> Bool = { _ in true }
    ) {
        guard !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if slot?.belongs(to: utteranceId) == true {
            slot?.english = english
            slot?.originalRows.update(english, fits: fitsOriginal)
            if let chinese, !chinese.isEmpty { slot?.chinese = chinese }
            slot?.source = source
        } else {
            let previous = history.last { $0.belongs(to: utteranceId) }
            var rows = previous?.originalRows.continuation() ?? OriginalCaptionRows()
            rows.update(english, fits: fitsOriginal)
            guard !rows.rows.isEmpty else { return }
            if slot != nil { rollUpSlot() }
            slot = BandLine(
                id: previous == nil ? utteranceId : UUID(), translationKey: nil, english: english,
                chinese: (chinese?.isEmpty == false) ? chinese : nil,
                source: source, isFinal: false, expectsTranslation: expectsTranslation
            )
            slot?.continuedUtterance = previous == nil ? nil : utteranceId
            slot?.originalRows = rows
            if !hasPresented(utteranceId) {
                recentlyPresented[source, default: []].append(utteranceId)
                // Track separately so fast utterances from the other source
                // cannot evict a preview whose speaker result is still pending.
                if (recentlyPresented[source]?.count ?? 0) > 8 { recentlyPresented[source]?.removeFirst() }
            }
        }
    }

    /// A finalized utterance, already cleaned and split into sentences.
    /// `sentences` pairs each sentence with its transcript id (translation key).
    /// When `utteranceId` matches the slot, the LAST sentence morphs the slot in
    /// place and earlier ones insert above it; otherwise (a background source, or
    /// no interim ever shown) everything inserts into history directly.
    /// - Parameter provisional: the live translation, split to match
    ///   `sentences`, keyed by translation key. Shown until each sentence's
    ///   accurate translation arrives, so the second caption never blanks for
    ///   text that has already been translated once.
    public mutating func commit(
        utteranceId: UUID?,
        source: AudioSourceType,
        sentences: [(key: UUID, english: String)],
        expectsTranslation: Bool,
        speakerLabel: String? = nil,
        provisional: [UUID: String] = [:],
        fitsOriginal: (String) -> Bool = { _ in true }
    ) {
        guard !sentences.isEmpty else { return }
        if isPinned { pendingWhilePinned += sentences.count }

        if let utteranceId, slot?.belongs(to: utteranceId) == true {
            for s in sentences.dropLast() {
                history.append(BandLine(
                    id: s.key, translationKey: s.key, english: s.english,
                    chinese: provisional[s.key],
                    source: source, isFinal: true, expectsTranslation: expectsTranslation,
                    speakerLabel: speakerLabel))
            }
            let last = sentences[sentences.count - 1]
            slot?.english = last.english
            slot?.originalRows.update(last.english, final: true, fits: fitsOriginal)
            slot?.translationKey = last.key
            slot?.isFinal = true
            slot?.expectsTranslation = expectsTranslation
            slot?.source = source
            slot?.speakerLabel = speakerLabel
            // The slot keeps its live translation across the morph on purpose —
            // that is what stops the second caption blanking for the second or
            // two before the accurate one lands.
            //
            // When the utterance split into several sentences, that live text
            // covers all of them, so it cannot stand as the translation of the one
            // left in the slot. Multi-part callers can provide an honestly
            // paired provisional mapping; absent entries remain pending.
            if sentences.count > 1 {
                slot?.chinese = provisional[last.key]
            }
        } else if let utteranceId, sentences.count == 1,
                  let index = history.lastIndex(where: { $0.belongs(to: utteranceId) }),
                  let sentence = sentences.first {
            history[index].english = sentence.english
            history[index].originalRows.appendUnseenFinal(sentence.english, fits: fitsOriginal)
            history[index].translationKey = sentence.key
            history[index].speakerLabel = speakerLabel
            history[index].isFinal = true
            if let text = provisional[sentence.key] { history[index].chinese = text }
        } else {
            // Background commit: roll a finalized slot up first so ordering stays
            // chronological, then append these sentences as history.
            if let s = slot, s.isFinal { rollUpSlot() }
            for s in sentences {
                history.append(BandLine(
                    id: s.key, translationKey: s.key, english: s.english,
                    chinese: provisional[s.key],
                    source: source, isFinal: true, expectsTranslation: expectsTranslation,
                    speakerLabel: speakerLabel))
            }
        }
        for index in history.indices where history[index].originalRows.rows.isEmpty {
            let text = history[index].english
            history[index].originalRows.update(text, final: true, fits: fitsOriginal)
        }
        trimCommitted()
    }

    /// Route a translation result to the line that owns `key`.
    public mutating func translation(key: UUID, text: String) {
        if slot?.translationKey == key {
            slot?.chinese = text
            return
        }
        if slot?.receiveGroupTranslation(key: key, text: text) == true { return }
        for index in history.indices {
            if history[index].translationKey == key {
                history[index].chinese = text
                return
            }
            if history[index].receiveGroupTranslation(key: key, text: text) { return }
        }
    }

    /// Update the live translation of the current (not yet finalized) slot.
    public mutating func interimTranslation(utteranceId: UUID, text: String) {
        guard let s = slot, s.belongs(to: utteranceId), !s.isFinal, !text.isEmpty else { return }
        slot?.chinese = text
    }

    /// Drop an in-progress slot whose utterance produced nothing usable (e.g.
    /// the cleanup reduced it to pure filler) — otherwise the dimmed interim
    /// line would linger with a blinking caret and never finalize.
    public mutating func discard(utteranceId: UUID) {
        guard let s = slot, s.belongs(to: utteranceId), !s.isFinal else { return }
        slot = nil
    }

    /// A grouped final can arrive after some rows have been read. Close its
    /// preview without replacing those rows with the diarized transcript.
    public mutating func addPresentedSpeakerGroup(
        utteranceId: UUID, key: UUID, original: String, speaker: String?, isLast: Bool
    ) {
        if isPinned { pendingWhilePinned += 1 }
        if slot?.belongs(to: utteranceId) == true {
            slot?.addSpeakerPart(key: key, original: original, speaker: speaker, isLast: isLast)
        } else if let index = history.lastIndex(where: { $0.belongs(to: utteranceId) }) {
            history[index].addSpeakerPart(key: key, original: original, speaker: speaker, isLast: isLast)
        }
    }

    public mutating func previewOriginalFinal(
        utteranceId: UUID, text: String, fitsOriginal: (String) -> Bool
    ) {
        if slot?.belongs(to: utteranceId) == true {
            slot?.originalRows.update(text, final: true, fits: fitsOriginal)
        } else if let index = history.lastIndex(where: { $0.belongs(to: utteranceId) }) {
            history[index].originalRows.appendUnseenFinal(text, fits: fitsOriginal)
        }
    }

    // MARK: - Pin / lifecycle

    public mutating func pin() {
        guard !isPinned else { return }
        isPinned = true
        pinnedCommitted = history
        pinnedSlot = slot
        pendingWhilePinned = 0
    }

    public mutating func unpin() {
        guard isPinned else { return }
        isPinned = false
        pinnedCommitted = []
        pinnedSlot = nil
        pendingWhilePinned = 0
    }

    public mutating func togglePin() { isPinned ? unpin() : pin() }

    public mutating func clear() {
        history = []
        recentlyPresented = [:]
        slot = nil
        isPinned = false
        pendingWhilePinned = 0
        pinnedCommitted = []
        pinnedSlot = nil
    }

    // MARK: - Private

    private mutating func rollUpSlot() {
        guard var s = slot else { return }
        if !s.isFinal { s.rolledUp = true }
        history.append(s)
        slot = nil
        trimCommitted()
    }

    private mutating func trimCommitted() {
        // Keep enough recent content for every supported overlay count even
        // when the user is currently displaying just one line.
        let capacity = max(3, displayLimit)
        if history.count > capacity {
            history.removeFirst(history.count - capacity)
        }
    }
}
