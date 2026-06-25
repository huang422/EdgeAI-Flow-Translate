import AppKit
import Carbon.HIToolbox

/// Registers system-wide keyboard shortcuts (work even when another app, e.g. Zoom,
/// is focused). Uses Carbon `RegisterEventHotKey`, which needs no Accessibility
/// permission.
///
/// A single shared event handler dispatches to the right callback by hot-key id, so
/// any number of shortcuts can coexist (registering several `GlobalHotKey` instances
/// each with their own handler used to make every press fire every callback).
final class GlobalHotKeyCenter {
    static let shared = GlobalHotKeyCenter()

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var callbacks: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1
    private let signature = OSType(0x464C5448) // 'FLTH'

    private init() { installDispatcher() }

    /// Register a shortcut. `keyCode` is a virtual key code (e.g. `kVK_ANSI_C`),
    /// `modifiers` a Carbon mask (e.g. `controlKey | optionKey`). The callback runs
    /// on the main thread. Returns false if registration failed.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        let id = nextId
        nextId += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRefs[id] = ref
        callbacks[id] = handler
        return true
    }

    private func installDispatcher() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr else { return noErr }
                let center = Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                center.callbacks[hotKeyID.id]?()
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )
    }
}
