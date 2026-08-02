import SwiftUI
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

        /// History (older finalized) line opacity; the latest unit is always 1.0.
        static let historyOpacity: Double = 0.46
        static let interimOpacity: Double = 0.62

        static let enterDuration: Double = 0.18   // 180ms ease-out fade + slide
        static let controlsDuration: Double = 0.16
        /// In-place morph (interim → finalized) crossfade duration.
        static let morphDuration: Double = 0.15
        /// History-line fade-out duration on eviction.
        static let evictDuration: Double = 0.25
    }

    // MARK: - Caption band geometry

    /// Fixed content height of the floating caption band, derived ONLY from
    /// settings (font size, history lines, second caption on/off) — never from
    /// the live text. This is what keeps the overlay's frame constant while
    /// captions stream (the anti-jump core): content is bottom-aligned inside
    /// and clipped at the top when a long sentence wraps.
    static func bandContentHeight(fontSize: Double, historyLines: Int, secondLine: Bool) -> CGFloat {
        let en = ceil(fontSize * 1.4)                                // primary line height
        let zh = secondLine ? ceil(fontSize * 0.82 * 1.45) + 4 : 0   // translation line + gap
        let unit = en + zh
        let slots = CGFloat(max(0, historyLines) + 1)                // history + current
        let spacing = CGFloat(max(0, historyLines)) * 12             // inter-unit spacing
        return slots * unit + spacing + en                           // +1 line wrap headroom
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
