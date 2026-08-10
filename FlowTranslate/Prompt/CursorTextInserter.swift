import AppKit
import Foundation

/// Types text into whatever field currently has focus, in any application.
///
/// macOS gives no supported way to write directly into another app's text field,
/// so this does what every dictation tool does: put the text on the pasteboard,
/// synthesize ⌘V, then put the pasteboard back. That requires the **Accessibility**
/// permission — synthesized keyboard events are rejected without it.
///
/// The pasteboard is restored because it is shared state the user did not offer
/// up. Losing whatever they had copied in order to paste a prompt would be a
/// rude and confusing side effect.
enum CursorTextInserter {

    /// How long the pasted text stays on the pasteboard before the user's own
    /// contents go back.
    ///
    /// 400 ms failed intermittently: a busy app can take longer to receive the
    /// ⌘V, decide it owns the keystroke and *then* read the pasteboard, and
    /// restoring first meant it read the previous clipboard. A second is
    /// imperceptible — the text is already in place.
    private static let restoreDelay: Duration = .milliseconds(1000)

    /// Accessibility trust lives in `Permissions`, alongside the microphone and
    /// screen-recording checks and the TCC reset list — one home, not two.
    enum InsertError: LocalizedError {
        case notTrusted
        case eventSourceUnavailable
        case pasteboardWriteFailed

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "需要「輔助使用」權限才能插入文字 Accessibility permission required"
            case .eventSourceUnavailable:
                return "無法送出鍵盤事件 Could not synthesize the paste"
            case .pasteboardWriteFailed:
                return "無法寫入剪貼簿 Could not write to the clipboard"
            }
        }
    }

    /// Paste `text` at the current cursor, restoring the pasteboard afterwards.
    ///
    /// A caller must not write to the pasteboard before calling this — the
    /// snapshot below would capture that write and put it back as the user's own.
    @MainActor
    static func insert(_ text: String) async throws {
        guard !text.isEmpty else { return }
        guard Permissions.accessibilityAuthorized else { throw InsertError.notTrusted }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        // **Confirm the text is on the pasteboard before pasting.** A refused
        // `setString` is not a failed insert but a *wrong* one: `clearContents()`
        // has already bumped the change count and ⌘V goes out regardless, so what
        // lands in the user's document is whatever the pasteboard holds instead.
        // The return value and the read-back answer different questions — whether
        // the write was accepted, and whether what came out is what went in.
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        guard wrote, pasteboard.string(forType: .string) == text else {
            restore(saved, to: pasteboard)
            throw InsertError.pasteboardWriteFailed
        }

        // Wait for ⌃⌥ to come back up first: the physical modifier state is
        // combined with the synthesized event at the HID tap, so a paste sent
        // while the shortcut is still held arrives as ⌃⌥⌘V — paste in no app.
        await waitForModifiersToClear()

        do {
            try postCommandV()
        } catch {
            restore(saved, to: pasteboard)
            throw error
        }

        try? await Task.sleep(for: restoreDelay)
        restore(saved, to: pasteboard)
    }

    /// Longest to wait for the modifier keys to be released.
    ///
    /// Bounded because a key can be physically stuck or held deliberately, and a
    /// paste that never happens is worse than one that arrives with the wrong
    /// flags — only one of those tells the user something happened.
    ///
    private static let modifierWait: Duration = .milliseconds(600)
    private static let modifierPoll: Duration = .milliseconds(25)

    private static func waitForModifiersToClear() async {
        let blocking: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        var waited: Duration = .zero
        while waited < modifierWait {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            guard !flags.intersection(blocking).isEmpty else { return }
            try? await Task.sleep(for: modifierPoll)
            waited += modifierPoll
        }
    }

    // MARK: - Keyboard synthesis

    private static func postCommandV() throws {
        // A private (per-app) source: the events are for the frontmost app, and
        // this avoids disturbing the global event state.
        guard let source = CGEventSource(stateID: .privateState) else {
            throw InsertError.eventSourceUnavailable
        }
        let vKeyCode: CGKeyCode = 9   // ANSI "v"
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { throw InsertError.eventSourceUnavailable }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Pasteboard preservation

    /// Every representation of the current first item, so restoring keeps rich
    /// content (styled text, an image) rather than flattening it to a string.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType: Data] {
        var saved: [NSPasteboard.PasteboardType: Data] = [:]
        for type in pasteboard.types ?? [] {
            if let data = pasteboard.data(forType: type) { saved[type] = data }
        }
        return saved
    }

    private static func restore(_ saved: [NSPasteboard.PasteboardType: Data], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        pasteboard.declareTypes(Array(saved.keys), owner: nil)
        for (type, data) in saved {
            pasteboard.setData(data, forType: type)
        }
    }
}
