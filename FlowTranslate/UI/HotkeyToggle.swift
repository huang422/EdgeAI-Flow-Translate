import SwiftUI

/// A labelled switch for one global hotkey, with the key combination shown as a
/// keycap beside it.
///
/// Both of the app's headline features are reached by a global hotkey — ⌃⌥C for
/// the floating captions, ⌃⌥Space for dictation anywhere — and until this existed
/// they were presented as two unrelated things. Captions had a tinted switch on
/// the main action row with the combination beside it; dictation had an 11 pt
/// checkbox at the bottom of an inspector group, below the rulebook buttons. The
/// same kind of control, at two sizes, in two styles, with two levels of
/// prominence, for the two things the app is for.
///
/// One view, so they cannot drift again. The keycap is part of the control rather
/// than a caption next to it: the combination *is* the feature, and a user who
/// scans the window for "how do I do this without the window" needs to find it
/// without reading.
struct HotkeyToggle: View {
    /// What the hotkey does, in the app's `中文 English` form.
    let title: String
    /// The combination, written the way macOS writes it: `⌃⌥Space`.
    let keys: String
    @Binding var isOn: Bool
    /// Shown on hover — the one place there is room to say what it costs or
    /// requires (Accessibility, a running meeting).
    var help: String = ""

    /// Green, and only on the switch.
    ///
    /// The switch is the control, so it carries the app's "on" green. Everything
    /// else — icon, keycap, border — uses one fixed accent instead, because a
    /// card where every element changes colour reads as decoration; a card with a
    /// single lit border reads as a state.
    private var switchGreen: Color { CaptionTheme.Palette.mic }

    /// The card's own colour — amber, and always present.
    ///
    /// Its own entry in the palette rather than a borrowed one. Blue already
    /// means system audio and primary action, green means microphone, red means
    /// Stop, violet means the privacy note — a hotkey card in any of them reads
    /// as one more of that thing.
    ///
    /// Always drawn, never absent. An outline that appears only when the feature
    /// is on cannot advertise a feature that is off, and off is exactly when the
    /// user needs to notice it. State is carried by the switch.
    private var accent: Color { CaptionTheme.Palette.hotkey }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn
                        ? CaptionTheme.Palette.inkPrimary : CaptionTheme.Palette.inkSecondary)
                    .lineLimit(1)
                Text(keys)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    // Legible when off, too. A keycap that dims with the control
                    // it belongs to hides the answer to "what turns this on"
                    // exactly when it is being looked for.
                    .foregroundStyle(accent)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(switchGreen)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        // A card, not a row. Everything else on these pages is a plain control in
        // a stack; giving these two a filled, outlined container is what makes
        // them read as a feature rather than as one more setting — and the fill
        // and border carry the on/off state at a glance, from across the room.
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(accent.opacity(isOn ? 0.16 : 0.10))
        )
        // Lit whether the switch is on or off. An outline that appears only when
        // the feature is running cannot advertise a feature that is not — and not
        // running is exactly when the user needs to notice it. State is carried
        // by the switch, which is the control that expresses it.
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(accent, lineWidth: 1.5)
        )
        .shadow(color: accent.opacity(0.4), radius: 5)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .fixedSize(horizontal: true, vertical: false)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(keys)")
    }
}
