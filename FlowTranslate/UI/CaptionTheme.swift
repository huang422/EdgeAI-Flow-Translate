import SwiftUI
import AppKit
import FlowTranslateCore

/// Centralised design tokens for the redesigned UI and floating overlay
/// (Flow-Translate-Redesign-Spec.md §1). Keep all colours, type and metrics here so
/// the main panel, settings and overlay stay visually consistent.
enum CaptionTheme {

    // MARK: - Colour

    enum Palette {
        // Window / surfaces
        static let canvas        = Color(hex: 0x121214)
        static let surface       = Color(hex: 0x1E1E21)
        static let surfaceRaised = Color(hex: 0x26262A)
        static let hairline      = Color.white.opacity(0.10)

        // Text
        static let inkPrimary     = Color(hex: 0xF5F5F7)   // primary / English original
        static let inkTranslation = Color(hex: 0xB6BCC8)   // translation (low-chroma cool grey)
        static let inkSecondary   = Color(hex: 0xA1A6B0)   // secondary UI text
        static let inkTertiary    = Color(hex: 0x6E727C)   // weakest / annotations

        // Semantic (matches Apple system colours)
        static let accentSystem = Color(hex: 0x0A84FF)   // system-audio source / primary action / toggle on
        static let mic          = Color(hex: 0x30D158)   // microphone source / listening
        static let stopRec      = Color(hex: 0xFF453A)   // Stop / recording red dot
        /// Amber — the global hotkeys, and nothing else.
        ///
        /// Every other accent already means something on these pages: blue is
        /// the system-audio source and the primary action, green is the
        /// microphone, red is Stop, violet is the privacy note. A hotkey card in
        /// any of them reads as one more of that thing. Amber is unused, so it
        /// belongs to the two shortcuts alone.
        static let hotkey       = Color(hex: 0xFFB340)
        static let pin          = Color(hex: 0xFF9F0A)   // pin / pause
        static let privacy      = Color(hex: 0x5E5CE6)   // privacy emphasis

        /// Overlay scrim tint; combined with the configured opacity.
        static let overlayScrim = Color(hex: 0x16161A)

        /// Leading dot colour for a caption unit, by audio source.
        static func sourceDot(_ source: AudioSourceType) -> Color {
            source == .microphone ? mic : accentSystem
        }
    }

    // MARK: - Metrics

    enum Metric {
        static let scrimCorner: CGFloat = 16
        static let windowCorner: CGFloat = 12
        static let chipCorner: CGFloat = 8

        static let overlayMaxWidth: CGFloat = 600
        /// Horizontal scrim padding on either side of the caption text block.
        static let overlayScrimHPadding: CGFloat = 22
        /// Full overlay panel width (caption block + both scrim paddings). The idle
        /// pill is laid out at this same width so the centre-anchored window never
        /// shifts horizontally when content changes idle ↔ caption.
        static let overlayTotalWidth: CGFloat = overlayMaxWidth + overlayScrimHPadding * 2
        static let overlayBottomFraction: CGFloat = 0.16   // default: 16% up from the bottom (a bit higher)

        static let fontMin: Double = 12
        static let fontMax: Double = 22
        static let opacityMin: Double = 0.40
        static let opacityMax: Double = 0.90

        // No per-state text opacity: every caption line renders at full strength,
        // so nothing on screen changes brightness when a sentence finalizes.
        // "In progress" is carried by the breathing dot, caret and underline.

        // Band layout constants. `bandContentHeight` and the views MUST agree on
        // these — if the reserved height and the rendered rows ever disagree the
        // band silently clips or leaves a gap, so they share one definition.
        static let dotSize: CGFloat = 6
        /// Gap between the dot, the speaker slot and the caption text.
        static let gutterSpacing: CGFloat = 8
        /// Gap between a unit's recognition row and its translation row.
        static let rowGap: CGFloat = 4
        /// Gap between caption units.
        static let unitSpacing: CGFloat = 12

        static let enterDuration: Double = 0.18   // 180ms ease-out fade + slide
        static let controlsDuration: Double = 0.16
        /// In-place morph (interim → finalized) crossfade duration.
        static let morphDuration: Double = 0.15
        /// History-line fade-out duration on eviction.
        static let evictDuration: Double = 0.25
    }

    // MARK: - Caption band geometry

    /// Rows the live line may wrap to — **and** the rows its own area reserves.
    ///
    /// One number for both, because a reserved area is the only thing that keeps
    /// the live line's geometry still, and an area cannot reserve fewer rows than
    /// it allows without the extra row pushing something.
    ///
    /// Three, so the cap is not met in practice: roughly 225 Latin or 111 CJK
    /// characters at the default 600 pt band and 16 pt type, well past what the
    /// endpointer hands over as one utterance. The cost is paid in blank rows
    /// under a short caption, which is visible and still; the alternative was an
    /// ellipsis, or a box that resizes on every interim revision — which is what
    /// sizing this area to its text actually did.
    static let liveRecognitionRows = 3

    /// Rows a finalized line may wrap to.
    ///
    /// The same as the live line. A finalized caption is the same sentence one
    /// moment later, so giving it less room only means it says less than it did
    /// while it was being spoken — which reads as the app taking words away at
    /// the moment you stop talking.
    ///
    /// Unlike the live line this is a **cap, not a reservation**: the history
    /// area takes its own height, so a one-row sentence costs one row.
    static let historyRecognitionRows = liveRecognitionRows

    /// Rows the translation may wrap to.
    ///
    /// One. Every reserved row past what the sentence uses becomes slack below
    /// the translation — see `liveRegion` — and this row is the closest to the
    /// band's lower border, so it is the most expensive place to reserve space
    /// that is usually empty. Chinese is compact enough that a translation of a
    /// three-row source normally fits one row.
    static let translationRows = 1

    /// Height of one translation text row, without the gap above it.
    static func translationTextRowHeight(_ fontSize: Double) -> CGFloat {
        ceil(fontSize * 0.82 * 1.45)
    }

    /// Height reserved for the utterance being spoken.
    ///
    /// **A number, not a measurement, and that is the point.** Sizing this area
    /// to its text means it changes on every interim revision — several times a
    /// second while anybody is speaking — and the panel is resized to follow,
    /// always a run loop behind. That was tried, to remove the blank row a short
    /// caption leaves in a reserved area, and it took the whole overlay's
    /// stability with it.
    ///
    /// So this is the one area that reserves rows it may not use. The finalized
    /// lines above take their own height, which is what lets the top edge sit on
    /// the top of the oldest caption rather than on a block of reserved blank.
    static func liveUnitHeight(_ fontSize: Double, secondLine: Bool) -> CGFloat {
        CGFloat(liveRecognitionRows) * rowHeight(fontSize)
            + (secondLine
               ? Metric.rowGap + CGFloat(translationRows) * translationTextRowHeight(fontSize)
               : 0)
    }

    /// Height of ONE recognition row.
    static func rowHeight(_ fontSize: Double) -> CGFloat { ceil(fontSize * 1.4) }


    /// Font size of the diarized speaker name in the overlay.
    static func speakerLabelSize(_ fontSize: Double) -> CGFloat { max(10, fontSize - 5) }

    /// Fixed width of the speaker-name column, so the caption text starts at the
    /// same x whether or not the label has arrived yet (it only does at
    /// finalize).
    ///
    /// MEASURED, not estimated: a `size × 5` rule of thumb came out ~2 pt under
    /// "Speaker 9" at 11 pt and ~9 pt under "Speaker 88" at 17 pt, so the column
    /// truncated the very labels it exists to show. The same applies to counting
    /// characters — `DeepSeek` and `Nemotron` are both eight characters and
    /// `DeepSeek` renders wider — so every candidate is measured.
    ///
    /// **Two widths, not one.** Speakers are named `Claude Mango` rather than
    /// `Speaker 1`, and the full name is 50% wider than the numbered label it
    /// replaced: 148 pt at the maximum caption size, out of a 600 pt caption
    /// block. Reserving that on every row of the floating band — including the
    /// rows with no label — would spend a quarter of the caption width on a
    /// column that is usually empty. So the band shows the model half alone
    /// (`Claude`, unique within a session and *narrower* than "Speaker 88" was),
    /// and the transcript window, which has the room, shows the full name.
    @MainActor
    static func speakerSlotWidth(labelSize: CGFloat, style: SpeakerLabelStyle = .wrapped) -> CGFloat {
        // Memoized. The answer depends only on a font size and a fixed candidate
        // list, but the call sites are `View` body properties — one per caption
        // row, twice per row (the column and the second row's indent) — so it ran
        // on every interim update. Measured at 211 µs a pass over the 22
        // candidates, that was ~17 ms of main-thread work per second spent
        // recomputing a constant, at a font size that changes only when the user
        // drags a slider.
        let key = SlotKey(labelSize: labelSize, style: style)
        if let cached = slotWidths[key] { return cached }
        let font = NSFont.systemFont(ofSize: labelSize, weight: .bold)
        let widest = style.candidates.reduce(CGFloat(0)) { widest, candidate in
            max(widest, (candidate as NSString).size(withAttributes: [.font: font]).width)
        }
        let width = ceil(widest) + 2
        slotWidths[key] = width
        return width
    }

    private struct SlotKey: Hashable {
        let labelSize: CGFloat
        let style: SpeakerLabelStyle
    }

    /// Bounded by construction: the key is a font size the user picks from a
    /// 12–22 range and one of three styles, so this holds a handful of entries
    /// for the life of the process.
    @MainActor private static var slotWidths: [SlotKey: CGFloat] = [:]

    /// Which form of the generated speaker name a column has to fit.
    /// One style, because both speaker columns lay the name out the same way.
    ///
    /// A `short` (model half only) and a `full` (one line) case lived here while
    /// the band and the transcript disagreed about which to show. They agree now,
    /// and an unused case in a sizing enum is a size nothing is measured at —
    /// which is how the column ends up fitting a name form the app never renders.
    enum SpeakerLabelStyle: Hashable {
        /// `Claude` above `Mango`. Sized to the wider half; nothing abbreviated.
        case wrapped

        var candidates: [String] {
            switch self {
            // The numbered fallback is covered by `allNameHalves`: past ten
            // speakers the pools are exhausted and the halves become `Speaker`
            // and a count, and a column that cannot fit its own fallback is the
            // bug this function was written to stop.
            case .wrapped: return SpeakerNamer.allNameHalves
            }
        }
    }

    // MARK: - Type

    /// English original (primary) font for the overlay at a given size.
    static func primaryFont(_ size: Double) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    /// Translation (secondary) font — ~0.82× the primary size.
    static func translationFont(_ size: Double) -> Font {
        .system(size: size * 0.82, weight: .regular, design: .default)
    }
}

extension Color {
    /// Build a colour from a 0xRRGGBB integer literal.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
