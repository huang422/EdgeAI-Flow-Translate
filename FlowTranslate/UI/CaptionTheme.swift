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

    /// Recognition rows the viewport shows per caption unit. Two means a wrapped
    /// sentence is fully readable without touching anything; anything longer
    /// scrolls rather than being cut off.
    static let unitRows = 2

    /// Height of the floating caption band's VIEWPORT, derived ONLY from settings
    /// (font size, history lines, second caption on/off) — never from the live
    /// text. This is what keeps the overlay's frame constant while captions
    /// stream (the anti-jump core).
    ///
    /// The band scrolls inside this window, bottom-anchored, so text that no
    /// longer fits moves out of view instead of being truncated away: the newest
    /// words stay at a fixed height on screen. What remains scrollable is the
    /// lines the band still holds — `CaptionBandState` drops finalized units past
    /// `historyLimit`, so this is not a record of the whole meeting; that lives in
    /// the transcript store.
    static func bandContentHeight(fontSize: Double, historyLines: Int, secondLine: Bool) -> CGFloat {
        let unit = CGFloat(unitRows) * rowHeight(fontSize)
            + (secondLine ? translationRowHeight(fontSize) : 0)
        let history = CGFloat(max(0, historyLines))
        return (history + 1) * unit + history * Metric.unitSpacing
    }

    /// Height of ONE recognition row. Both the band's reserved height and each
    /// row's frame come from here, so they cannot drift apart.
    static func rowHeight(_ fontSize: Double) -> CGFloat { ceil(fontSize * 1.4) }

    /// Height of the translation row including the gap above it.
    static func translationRowHeight(_ fontSize: Double) -> CGFloat {
        ceil(fontSize * 0.82 * 1.45) + Metric.rowGap
    }

    /// Font size of the diarized speaker name in the overlay.
    static func speakerLabelSize(_ fontSize: Double) -> CGFloat { max(10, fontSize - 5) }

    /// Fixed width of the speaker-name column, so the caption text starts at the
    /// same x whether or not the label has arrived yet (it only does at
    /// finalize). Shared by the overlay and the transcript window so both indent
    /// identically.
    ///
    /// MEASURED, not estimated: a `size × 5` rule of thumb came out ~2 pt under
    /// "Speaker 9" at 11 pt and ~9 pt under "Speaker 88" at 17 pt, so the column
    /// truncated the very labels it exists to show. FluidAudio names speakers
    /// `"Speaker <index>"`, so the column is sized for a two-digit index and a
    /// long meeting never starts showing an ellipsis.
    static func speakerSlotWidth(labelSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: labelSize, weight: .bold)
        let widest = "Speaker 88" as NSString
        return ceil(widest.size(withAttributes: [.font: font]).width) + 2
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
