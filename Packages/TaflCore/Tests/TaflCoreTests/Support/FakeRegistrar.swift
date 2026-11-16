@testable import TaflCore

final class FakeRegistrar: HotkeyRegistrar {
    enum Call: Hashable {
        case register(KeyChord)
        case unregister(HotkeyRegistration)
    }

    var taken: Set<KeyChord> = []
    /// Refuses a chord while a registration of it is live, as an exclusive Carbon registration
    /// does, even when the live one is the registrar's own.
    var isExclusive = false
    private(set) var calls: [Call] = []
    private var nextID: UInt32 = 1
    private var live: [HotkeyRegistration: KeyChord] = [:]

    func register(_ chord: KeyChord) -> HotkeyRegistration? {
        calls.append(.register(chord))
        if taken.contains(chord) { return nil }
        if isExclusive, live.values.contains(chord) { return nil }
        defer { nextID += 1 }
        let registration = HotkeyRegistration(id: nextID)
        live[registration] = chord
        return registration
    }

    func unregister(_ registration: HotkeyRegistration) {
        calls.append(.unregister(registration))
        live[registration] = nil
    }

    var registeredChords: [KeyChord] {
        calls.compactMap { if case .register(let chord) = $0 { chord } else { nil } }
    }
}
