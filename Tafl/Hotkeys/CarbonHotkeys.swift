import Carbon.HIToolbox

final class CarbonHotkeys {
    var onPress: ((UInt32) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private let signature: OSType = 0x7461_666C // 'tafl'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), hotKeyHandler, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    isolated deinit {
        hotKeys.values.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> OSStatus {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { hotKeys[id] = ref }
        return status
    }

    func unregister(id: UInt32) {
        guard let ref = hotKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    fileprivate func pressed(_ id: UInt32) {
        onPress?(id)
    }
}

private nonisolated let hotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let hotkeys = Unmanaged<CarbonHotkeys>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotkeys.pressed(hotKeyID.id) }
    return noErr
}
