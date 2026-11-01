import Carbon.HIToolbox
import CoreGraphics
import Foundation

public enum KeyboardLayoutReader27 {
    /// The characters the current layout prints for key codes 0 to 127, plain and with Shift.
    /// Text Input Sources are main-thread only, hence `@MainActor`.
    @MainActor
    public static func currentLayout() -> [UInt16: (plain: String, shifted: String)] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
        let keyboardType = UInt32(LMGetKbdType())
        var layout: [UInt16: (plain: String, shifted: String)] = [:]
        let bytes = CFDataGetBytePtr(layoutData)
        bytes?.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyLayout in
            for code in UInt16(0)..<128 {
                layout[code] = (
                    plain: translate(keyLayout, code, modifiers: 0, keyboardType: keyboardType),
                    shifted: translate(keyLayout, code, modifiers: UInt32(shiftKey >> 8) & 0xFF, keyboardType: keyboardType))
            }
        }
        return layout
    }

    @MainActor
    public static func observeChanges(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in handler() }
    }

    private static func translate(
        _ layout: UnsafePointer<UCKeyboardLayout>, _ code: UInt16, modifiers: UInt32, keyboardType: UInt32
    ) -> String {
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "" }
        return String(utf16CodeUnits: characters, count: length)
    }
}
