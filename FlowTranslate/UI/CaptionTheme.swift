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

        static let dotSize: CGFloat = 6
        /// Gap between the dot, the speaker slot and the caption text.
        static let gutterSpacing: CGFloat = 8
        /// Gap between a unit's recognition row and its translation row.
        static let rowGap: CGFloat = 4
        /// Gap between caption units.
        static let unitSpacing: CGFloat = 12

        static let controlsDuration: Double = 0.16
        /// History-line fade-out duration on eviction.
        static let evictDuration: Double = 0.25
    }

    static let speakerLabelSize: CGFloat = 10

    /// Measure the widest displayed name half once, including the source labels
    /// shown while diarization is still working.
    @MainActor static let speakerSlotWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: speakerLabelSize, weight: .bold)
        let candidates = SpeakerNamer.allNameHalves + ["系統音訊", "麥克風"]
        let widest = candidates.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + 2
    }()

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

/// The transcript and floating band use the same two-line name and fixed type.
struct CaptionSpeakerLabel: View {
    let name: String
    var reservesSpace = false

    var body: some View {
        Text(name.isEmpty && reservesSpace ? " \n " : SpeakerName.wrapping(name))
            .font(.system(size: CaptionTheme.speakerLabelSize, weight: .bold))
            .foregroundStyle(CaptionTheme.Palette.inkSecondary)
            .multilineTextAlignment(.leading)
            .lineLimit(2, reservesSpace: reservesSpace)
            .fixedSize()
            .frame(width: CaptionTheme.speakerSlotWidth, alignment: .leading)
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
