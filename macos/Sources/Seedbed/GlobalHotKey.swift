import AppKit
import Carbon.HIToolbox

/// A system-wide hot key via Carbon `RegisterEventHotKey`, which needs no
/// Accessibility or Input-Monitoring permission — unlike an NSEvent global
/// monitor, which does and which macOS can revoke silently.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    /// Default: ⌥⌘P (keyCode 35 = P).
    init?(keyCode: UInt32 = UInt32(kVK_ANSI_P),
          modifiers: UInt32 = UInt32(cmdKey | optionKey),
          action: @escaping () -> Void) {
        id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        GlobalHotKey.handlers[id] = action
        GlobalHotKey.installHandlerOnce()

        let hkID = EventHotKeyID(signature: OSType(0x50484B59 /* 'PHKY' */), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { GlobalHotKey.handlers[id] = nil; return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        GlobalHotKey.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { GlobalHotKey.handlers[hkID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
