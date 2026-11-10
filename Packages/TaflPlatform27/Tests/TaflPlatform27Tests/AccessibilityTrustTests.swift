import Testing
@testable import TaflPlatform27

@Test(arguments: [(Int32(0), true), (1, false), (2, false), (-1, false), (3, false), (Int32.max, false)])
func onlyTheGrantedValueCountsAsTrusted(value: Int32, trusted: Bool) {
    #expect(AccessibilityTrust.isTrusted(preflightResult: value) == trusted)
}

@Test func theReadIsTheMappedPreflightAnswerWhenTheSymbolResolved() {
    let granted: AccessibilityTrust.Preflight = { _, _ in 0 }
    let denied: AccessibilityTrust.Preflight = { _, _ in 1 }
    #expect(AccessibilityTrust.read(preflight: granted, fallback: { false }))
    #expect(!AccessibilityTrust.read(preflight: denied, fallback: { true }))
}

@Test func theReadIsTheFallbackWhenTheSymbolIsMissing() {
    #expect(AccessibilityTrust.read(preflight: nil, fallback: { true }))
    #expect(!AccessibilityTrust.read(preflight: nil, fallback: { false }))
}

@Test func aMissingSymbolResolvesToNoPreflight() {
    #expect(AccessibilityTrust.resolve(symbol: nil) == nil)
}

@Test func theCapabilityStateNamesWhereTheAnswerComes() {
    let direct = AccessibilityTrust.capability(preflightAvailable: true)
    let fallback = AccessibilityTrust.capability(preflightAvailable: false)
    #expect(direct.name == fallback.name)
    #expect(direct.isAvailable)
    #expect(fallback.isAvailable)
    #expect(direct.note != fallback.note)
}
