@testable import TaflCore

let v = ScreenRect(x: 0, y: 25, width: 1000, height: 775)
let u = ScreenRect(x: 0, y: 0, width: 3840, height: 1575)
let p = ScreenRect(x: 1000, y: 0, width: 1080, height: 1895)

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ScreenRect {
    ScreenRect(x: x, y: y, width: w, height: h)
}

func display(_ visible: ScreenRect) -> Display {
    Display(
        identity: DisplayIdentity(name: "Test", vendor: 1, model: 2, serial: 3),
        frame: visible,
        visibleFrame: visible
    )
}
