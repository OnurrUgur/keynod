import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility permission.
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerRef: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: Int, modifiers: Int, id: UInt32 = 1, action: @escaping () -> Void) {
        self.id = id
        Self.installHandler()
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B4E_4F44), id: id) // "KNOD"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private static func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let action = HotKey.actions[hotKeyID.id] else { return noErr }
            DispatchQueue.main.async { action() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.actions[id] = nil
    }
}
