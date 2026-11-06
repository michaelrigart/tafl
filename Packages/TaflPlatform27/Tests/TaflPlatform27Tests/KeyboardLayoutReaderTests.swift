import Testing
@testable import TaflPlatform27

@Test func deadKeyOptionIsTheMaskNotTheBitIndex() {
    // kUCKeyTranslateNoDeadKeysBit is the bit index 0; UCKeyTranslate wants the mask 1 << 0.
    // With 0 passed, ^ and ` translate to "" on ABC-AZERTY.
    #expect(KeyboardLayoutReader27.noDeadKeysOption == 1)
}
