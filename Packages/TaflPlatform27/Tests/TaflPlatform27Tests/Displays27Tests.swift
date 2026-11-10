import CoreGraphics
import Testing
import TaflCore
@testable import TaflPlatform27

private func raw(
    name: String = "Built-in Retina Display", vendor: UInt32 = 1552, model: UInt32 = 41033, serial: UInt32 = 0,
    frame: CGRect, visible: CGRect? = nil, safeAreaTop: CGFloat = 0
) -> RawDisplay27 {
    RawDisplay27(
        displayID: 1, name: name, vendor: vendor, model: model, serial: serial,
        frame: .init(frame), visibleFrame: .init(visible ?? frame), safeAreaTop: safeAreaTop)
}

@Test func aRawDisplayMapsToTheCoreDisplayWithItsDecimalIdentifier() {
    let display = Displays27.display(
        from: raw(name: "LG UltraFine", vendor: 7789, model: 30648, serial: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)),
        dock: nil)
    #expect(display.identity == DisplayIdentity(name: "LG UltraFine", vendor: 7789, model: 30648, serial: 1))
    #expect(display.identity.identifier == "7789-30648-1")
    #expect(display.frame == ScreenRect(x: 0, y: 0, width: 2560, height: 1440))
}

@Test func theVisibleFrameIsTheCorrectedOne() {
    let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let dock = DockState(
        isAutoHidden: false, frame: .init(CGRect(x: 400, y: 830, width: 640, height: 62)), screenFrames: [.init(frame)])
    let display = Displays27.display(
        from: raw(frame: frame, visible: CGRect(x: 0, y: 25, width: 1440, height: 875)), dock: dock)
    #expect(display.visibleFrame == ScreenRect(x: 0, y: 25, width: 1440, height: 805))
}

@Test func theDarkWakePlaceholderDisplayIsMarked() {
    // Log 20 of the feasibility probe: no name, identifier 1970170734-1986622068-0, 1920 x 1080.
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let placeholder = Displays27.display(from: raw(name: "", vendor: 1_970_170_734, model: 1_986_622_068, frame: frame), dock: nil)
    #expect(placeholder.isPlaceholder)
    #expect(placeholder.identity.identifier == "1970170734-1986622068-0")
}

@Test func aRealDisplayIsNotAPlaceholder() {
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    // A display with the placeholder's ids but a name, and a nameless one with other ids, are real.
    #expect(!Displays27.display(from: raw(name: "Studio", vendor: 1_970_170_734, model: 1_986_622_068, frame: frame), dock: nil).isPlaceholder)
    #expect(!Displays27.display(from: raw(name: "", vendor: 1552, model: 1_986_622_068, frame: frame), dock: nil).isPlaceholder)
    #expect(!Displays27.display(from: raw(name: "", vendor: 1_970_170_734, model: 41033, frame: frame), dock: nil).isPlaceholder)
}

@Test func theSafeAreaIsTheNotchInset() {
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let display = Displays27.display(from: raw(frame: frame, safeAreaTop: 38), dock: nil)
    #expect(display.visibleFrame == ScreenRect(x: 0, y: 38, width: 1512, height: 944))
}

@Test func displaysAreSortedByTopThenLeft() {
    let lowerLeft = raw(serial: 1, frame: CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    let upperRight = raw(serial: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
    let upperLeft = raw(serial: 3, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let displays = Displays27.displays(from: [lowerLeft, upperRight, upperLeft], dock: nil)
    #expect(displays.map(\.identity.serial) == [3, 2, 1])
}

@Test func aDockOnOneDisplayDoesNotShrinkTheOthers() {
    let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let dock = DockState(
        isAutoHidden: false, frame: .init(CGRect(x: 1740, y: 1010, width: 1320, height: 62)),
        screenFrames: [.init(left), .init(right)])
    let displays = Displays27.displays(
        from: [raw(serial: 1, frame: left, visible: CGRect(x: 0, y: 25, width: 1440, height: 875)),
               raw(serial: 2, frame: right, visible: CGRect(x: 1440, y: 25, width: 1920, height: 1055))],
        dock: dock)
    #expect(displays[0].visibleFrame == ScreenRect(x: 0, y: 25, width: 1440, height: 875))
    #expect(displays[1].visibleFrame == ScreenRect(x: 1440, y: 25, width: 1920, height: 985))
}

private func display(serial: UInt32, x: Double, y: Double, width: Double, height: Double) -> Display {
    let frame = ScreenRect(x: x, y: y, width: width, height: height)
    return Display(identity: DisplayIdentity(name: "D", vendor: 1, model: 1, serial: serial), frame: frame, visibleFrame: frame)
}

@Test func thePointerIsConvertedFromAppKitSpaceToTheDisplayContainingIt() {
    let displays = [
        display(serial: 1, x: 0, y: 0, width: 1440, height: 900),
        display(serial: 2, x: 1440, y: 0, width: 1920, height: 1080),
    ]
    let onRight = Pointer27.display(at: CGPoint(x: 2000, y: 300), primaryHeight: 900, in: displays)
    #expect(onRight?.serial == 2)
    let onLeft = Pointer27.display(at: CGPoint(x: 100, y: 800), primaryHeight: 900, in: displays)
    #expect(onLeft?.serial == 1)
}

@Test func theSeamBelongsToTheDisplayOnItsRight() {
    let displays = [
        display(serial: 1, x: 0, y: 0, width: 1440, height: 900),
        display(serial: 2, x: 1440, y: 0, width: 1920, height: 1080),
    ]
    #expect(Pointer27.display(at: CGPoint(x: 1440, y: 400), primaryHeight: 900, in: displays)?.serial == 2)
    #expect(Pointer27.display(at: CGPoint(x: 1439.5, y: 400), primaryHeight: 900, in: displays)?.serial == 1)
}

@Test func theTopEdgeOfTheScreenIsInsideIt() {
    let displays = [display(serial: 1, x: 0, y: 0, width: 1440, height: 900)]
    #expect(Pointer27.display(at: CGPoint(x: 10, y: 900), primaryHeight: 900, in: displays)?.serial == 1)
}

@Test func aPointerOutsideEveryDisplayIsNil() {
    let displays = [display(serial: 1, x: 0, y: 0, width: 1440, height: 900)]
    #expect(Pointer27.display(at: CGPoint(x: 5000, y: 100), primaryHeight: 900, in: displays) == nil)
}
