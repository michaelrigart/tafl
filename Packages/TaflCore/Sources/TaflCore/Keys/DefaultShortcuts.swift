import Foundation

/// Rectangle's alternate set as physical key positions, so they stay on the same keys on every layout.
public enum DefaultShortcuts {
    public static let chords: [Action: KeyChord] = {
        let base: Modifiers = [.control, .option]
        let display: Modifiers = [.control, .option, .command]
        return [
            .leftHalf: KeyChord(keyCode: NamedKey.left.keyCode, modifiers: base),
            .rightHalf: KeyChord(keyCode: NamedKey.right.keyCode, modifiers: base),
            .topHalf: KeyChord(keyCode: NamedKey.up.keyCode, modifiers: base),
            .bottomHalf: KeyChord(keyCode: NamedKey.down.keyCode, modifiers: base),
            .topLeft: KeyChord(keyCode: 32, modifiers: base),
            .topRight: KeyChord(keyCode: 34, modifiers: base),
            .bottomLeft: KeyChord(keyCode: 38, modifiers: base),
            .bottomRight: KeyChord(keyCode: 40, modifiers: base),
            .firstThird: KeyChord(keyCode: 2, modifiers: base),
            .centerThird: KeyChord(keyCode: 3, modifiers: base),
            .lastThird: KeyChord(keyCode: 5, modifiers: base),
            .firstTwoThirds: KeyChord(keyCode: 14, modifiers: base),
            .centerTwoThirds: KeyChord(keyCode: 15, modifiers: base),
            .lastTwoThirds: KeyChord(keyCode: 17, modifiers: base),
            .maximize: KeyChord(keyCode: NamedKey.return.keyCode, modifiers: base),
            .maximizeHeight: KeyChord(keyCode: NamedKey.up.keyCode, modifiers: base.union(.shift)),
            .center: KeyChord(keyCode: 8, modifiers: base),
            .restore: KeyChord(keyCode: NamedKey.delete.keyCode, modifiers: base),
            .larger: KeyChord(keyCode: 24, modifiers: base),
            .smaller: KeyChord(keyCode: 27, modifiers: base),
            .displayLeft: KeyChord(keyCode: NamedKey.left.keyCode, modifiers: display),
            .displayRight: KeyChord(keyCode: NamedKey.right.keyCode, modifiers: display),
            .displayUp: KeyChord(keyCode: NamedKey.up.keyCode, modifiers: display),
            .displayDown: KeyChord(keyCode: NamedKey.down.keyCode, modifiers: display),
            .displayUnderPointer: KeyChord(keyCode: 46, modifiers: display),
        ]
    }()
}
