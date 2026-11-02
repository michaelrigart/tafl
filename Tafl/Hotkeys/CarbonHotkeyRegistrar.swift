import Carbon.HIToolbox
import TaflCore

extension CarbonHotkeyRegistrar: @MainActor HotkeyRegistrar {}

final class CarbonHotkeyRegistrar {
    var onPress: ((HotkeyRegistration) -> Void)?

    private let hotkeys = CarbonHotkeys()
    private var nextID: UInt32 = 1

    init() {
        hotkeys.onPress = { [weak self] id in self?.onPress?(HotkeyRegistration(id: id)) }
    }

    func register(_ chord: KeyChord) -> HotkeyRegistration? {
        let id = nextID
        guard hotkeys.register(keyCode: UInt32(chord.keyCode), modifiers: Self.carbonModifiers(chord.modifiers), id: id) == noErr
        else { return nil }
        nextID += 1
        return HotkeyRegistration(id: id)
    }

    func unregister(_ registration: HotkeyRegistration) {
        hotkeys.unregister(id: registration.id)
    }

    private static func carbonModifiers(_ modifiers: Modifiers) -> UInt32 {
        var result = 0
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}
