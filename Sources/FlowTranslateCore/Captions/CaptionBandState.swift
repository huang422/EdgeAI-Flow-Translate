import Foundation

/// One line in the floating caption band.
///
/// `id` is the **view identity**: for the current utterance it is minted at the
/// first interim and survives the interim → finalized morph, so the view layer
/// updates the same element in place (no remove/insert jump). `translationKey`
/// is the transcript sentence id used to route translation results.
public struct BandLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var translationKey: UUID?
    public var english: String
    public var chinese: String?
    public var source: AudioSourceType
    public var isFinal: Bool
    /// Whether a translation is expected for this line (drives the "⋯" pending
    /// placeholder in the reserved second-line space).
    public var expectsTranslation: Bool

    public init(
        id: UUID,
        translationKey: UUID? = nil,
        english: String,
        chinese: String? = nil,
        source: AudioSourceType,
        isFinal: Bool,
        expectsTranslation: Bool = false
    ) {
        self.id = id
        self.translationKey = translationKey
        self.english = english
        self.chinese = chinese
        self.source = source
        self.isFinal = isFinal
        self.expectsTranslation = expectsTranslation
    }
}

/// Pure state machine for the floating caption band (broadcast "roll-up" model):
///
/// - The **slot** holds the current utterance: it appears with the first interim,
///   morphs **in place** on finalize (same identity → no view jump), and rolls up
///   into `committed` history only when the *next* utterance starts.
/// - `committed` keeps the last `historyLimit` finalized lines; older lines are
///   evicted (the view fades them out).
/// - Pinning freezes a snapshot for reading while counting missed sentences —
///   the `+N` badge — by **commit events**, not array-length diffs (which broke
///   once the buffer was full).
///
/// Value type, no clocks, no UI — fully unit-testable.
public struct CaptionBandState: Equatable, Sendable {
    public private(set) var committed: [BandLine] = []
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
    public var visibleCommitted: [BandLine] { isPinned ? pinnedCommitted : committed }
    /// Current-utterance line to draw (frozen snapshot while pinned).
    public var visibleSlot: BandLine? { isPinned ? pinnedSlot : slot }
    /// Whether anything is on screen.
    public var hasContent: Bool { visibleSlot != nil || !visibleCommitted.isEmpty }
    /// Latest finalized line (for the copy action).
    public var latestFinal: BandLine? {
        if let s = slot, s.isFinal { return s }
        return committed.last
    }

    // MARK: - Events

    /// Live partial for the active utterance. A new `utteranceId` starts a new
    /// utterance: a finalized slot rolls up into history first (the roll-up
    /// moment), an unfinalized one is replaced (its finalize arrives later via
    /// `commit` and is inserted as history).
    public mutating func interim(
        utteranceId: UUID,
        source: AudioSourceType,
        english: String,
        chinese: String?,
        expectsTranslation: Bool
    ) {
        if let s = slot, s.id != utteranceId {
            if s.isFinal { rollUpSlot() } else { slot = nil }
        }
        if slot?.id == utteranceId {
            slot?.english = english
            if let chinese, !chinese.isEmpty { slot?.chinese = chinese }
            slot?.source = source
        } else {
            slot = BandLine(
                id: utteranceId, translationKey: nil, english: english,
                chinese: (chinese?.isEmpty == false) ? chinese : nil,
                source: source, isFinal: false, expectsTranslation: expectsTranslation
            )
        }
    }

    /// A finalized utterance, already cleaned and split into sentences.
    /// `sentences` pairs each sentence with its transcript id (translation key).
    /// When `utteranceId` matches the slot, the LAST sentence morphs the slot in
    /// place and earlier ones insert above it; otherwise (a background source, or
    /// no interim ever shown) everything inserts into history directly.
    public mutating func commit(
        utteranceId: UUID?,
        source: AudioSourceType,
        sentences: [(key: UUID, english: String)],
        expectsTranslation: Bool
    ) {
        guard !sentences.isEmpty else { return }
        if isPinned { pendingWhilePinned += sentences.count }

        if let utteranceId, slot?.id == utteranceId {
            for s in sentences.dropLast() {
                committed.append(BandLine(
                    id: s.key, translationKey: s.key, english: s.english,
                    source: source, isFinal: true, expectsTranslation: expectsTranslation))
            }
            let last = sentences[sentences.count - 1]
            slot?.english = last.english
            slot?.translationKey = last.key
            slot?.isFinal = true
            slot?.expectsTranslation = expectsTranslation
            slot?.source = source
        } else {
            // Background commit: roll a finalized slot up first so ordering stays
            // chronological, then append these sentences as history.
            if let s = slot, s.isFinal { rollUpSlot() }
            for s in sentences {
                committed.append(BandLine(
                    id: s.key, translationKey: s.key, english: s.english,
                    source: source, isFinal: true, expectsTranslation: expectsTranslation))
            }
        }
        trimCommitted()
    }

    /// Route a translation result to the line that owns `key`.
    public mutating func translation(key: UUID, text: String) {
        if slot?.translationKey == key {
            slot?.chinese = text
        } else if let i = committed.firstIndex(where: { $0.translationKey == key }) {
            committed[i].chinese = text
        }
    }

    /// Update the live translation of the current (not yet finalized) slot.
    public mutating func interimTranslation(utteranceId: UUID, text: String) {
        guard let s = slot, s.id == utteranceId, !s.isFinal, !text.isEmpty else { return }
        slot?.chinese = text
    }

    /// Drop an in-progress slot whose utterance produced nothing usable (e.g.
    /// the cleanup reduced it to pure filler) — otherwise the dimmed interim
    /// line would linger with a blinking caret and never finalize.
    public mutating func discard(utteranceId: UUID) {
        guard let s = slot, s.id == utteranceId, !s.isFinal else { return }
        slot = nil
    }

    // MARK: - Pin / lifecycle

    public mutating func pin() {
        guard !isPinned else { return }
        isPinned = true
        pinnedCommitted = committed
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
        committed = []
        slot = nil
        isPinned = false
        pendingWhilePinned = 0
        pinnedCommitted = []
        pinnedSlot = nil
    }

    // MARK: - Private

    private mutating func rollUpSlot() {
        guard let s = slot else { return }
        committed.append(s)
        slot = nil
        trimCommitted()
    }

    private mutating func trimCommitted() {
        if committed.count > historyLimit {
            committed.removeFirst(committed.count - historyLimit)
        }
    }
}
