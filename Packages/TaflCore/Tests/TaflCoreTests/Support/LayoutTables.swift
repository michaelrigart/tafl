@testable import TaflCore

extension KeyboardLayoutTable {
    static let usANSI = KeyboardLayoutTable([
        0: KeyOutputs(plain: "a", shifted: "A"),
        2: KeyOutputs(plain: "d", shifted: "D"),
        3: KeyOutputs(plain: "f", shifted: "F"),
        5: KeyOutputs(plain: "g", shifted: "G"),
        8: KeyOutputs(plain: "c", shifted: "C"),
        12: KeyOutputs(plain: "q", shifted: "Q"),
        14: KeyOutputs(plain: "e", shifted: "E"),
        15: KeyOutputs(plain: "r", shifted: "R"),
        17: KeyOutputs(plain: "t", shifted: "T"),
        18: KeyOutputs(plain: "1", shifted: "!"),
        24: KeyOutputs(plain: "=", shifted: "+"),
        27: KeyOutputs(plain: "-", shifted: "_"),
        29: KeyOutputs(plain: "0", shifted: ")"),
        32: KeyOutputs(plain: "u", shifted: "U"),
        34: KeyOutputs(plain: "i", shifted: "I"),
        38: KeyOutputs(plain: "j", shifted: "J"),
        40: KeyOutputs(plain: "k", shifted: "K"),
        41: KeyOutputs(plain: ";", shifted: ":"),
        46: KeyOutputs(plain: "m", shifted: "M"),
    ])

    static let frenchAZERTY = KeyboardLayoutTable([
        0: KeyOutputs(plain: "q", shifted: "Q"),
        2: KeyOutputs(plain: "d", shifted: "D"),
        3: KeyOutputs(plain: "f", shifted: "F"),
        5: KeyOutputs(plain: "g", shifted: "G"),
        8: KeyOutputs(plain: "c", shifted: "C"),
        12: KeyOutputs(plain: "a", shifted: "A"),
        14: KeyOutputs(plain: "e", shifted: "E"),
        15: KeyOutputs(plain: "r", shifted: "R"),
        17: KeyOutputs(plain: "t", shifted: "T"),
        18: KeyOutputs(plain: "&", shifted: "1"),
        24: KeyOutputs(plain: "-", shifted: "_"),
        27: KeyOutputs(plain: ")", shifted: "°"),
        29: KeyOutputs(plain: "à", shifted: "0"),
        32: KeyOutputs(plain: "u", shifted: "U"),
        34: KeyOutputs(plain: "i", shifted: "I"),
        38: KeyOutputs(plain: "j", shifted: "J"),
        40: KeyOutputs(plain: "k", shifted: "K"),
        41: KeyOutputs(plain: "m", shifted: "M"),
        46: KeyOutputs(plain: ",", shifted: "?"),
    ])
}
