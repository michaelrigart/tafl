@testable import TaflCore

final class FakeRegistrar: HotkeyRegistrar {
    enum Call: Hashable {
        case register(KeyChord)
        case unregister(HotkeyRegistration)
    }

    var taken: Set<KeyChord> = []
    private(set) var calls: [Call] = []
    private var nextID: UInt32 = 1

    func register(_ chord: KeyChord) -> HotkeyRegistration? {
        calls.append(.register(chord))
        if taken.contains(chord) { return nil }
        defer { nextID += 1 }
        return HotkeyRegistration(id: nextID)
    }

    func unregister(_ registration: HotkeyRegistration) {
        calls.append(.unregister(registration))
    }

    var registeredChords: [KeyChord] {
        calls.compactMap { if case .register(let chord) = $0 { chord } else { nil } }
    }
}
