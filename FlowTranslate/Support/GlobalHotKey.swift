import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (works even when another app, e.g. Zoom, is
/// focused). Uses Carbon `RegisterEventHotKey`, which needs no Accessibility
/// permission. Used to toggle the floating caption overlay from anywhere.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code (e.g. `kVK_ANSI_C`).
    ///   - modifiers: Carbon modifier mask (e.g. `controlKey | optionKey`).
    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                me.callback()
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x464C5448) /* 'FLTH' */, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
