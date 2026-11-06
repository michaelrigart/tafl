import Testing
import TaflCore
@testable import TaflPlatform27

@Test func aKeyWithOutputsIsKept() {
    let table = KeyboardLayout27.table(from: [27: (plain: ")", shifted: "°")])
    #expect(table.outputs[27] == KeyOutputs(plain: ")", shifted: "°"))
}

@Test func aKeyWithNoOutputIsDropped() {
    let table = KeyboardLayout27.table(from: [10: (plain: "", shifted: ""), 27: (plain: ")", shifted: "°")])
    #expect(table.outputs.keys.sorted() == [27])
}

@Test func controlAndWhitespaceKeysAreDroppedButSpaceStays() {
    let table = KeyboardLayout27.table(from: [
        36: (plain: "\r", shifted: "\r"),
        48: (plain: "\t", shifted: "\u{19}"),
        51: (plain: "\u{8}", shifted: "\u{8}"),
        53: (plain: "\u{1B}", shifted: "\u{1B}"),
        117: (plain: "\u{7F}", shifted: "\u{7F}"),
        123: (plain: "\u{1C}", shifted: "\u{1C}"),
        49: (plain: " ", shifted: " "),
    ])
    #expect(table.outputs.keys.sorted() == [49])
}

@Test func theShiftedOutputIsKeptEvenWhenItIsEmpty() {
    let table = KeyboardLayout27.table(from: [0: (plain: "a", shifted: "")])
    #expect(table.outputs[0] == KeyOutputs(plain: "a", shifted: ""))
}
