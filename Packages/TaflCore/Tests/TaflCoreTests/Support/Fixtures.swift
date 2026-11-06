@testable import TaflCore

let v = ScreenRect(x: 0, y: 25, width: 1000, height: 775)
let u = ScreenRect(x: 0, y: 0, width: 3840, height: 1575)
let p = ScreenRect(x: 1000, y: 0, width: 1080, height: 1895)

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ScreenRect {
    ScreenRect(x: x, y: y, width: w, height: h)
}

/// A request placing the window at its left half, from the Left Half action.
func leftHalfRequest(for window: WindowHandle) -> MoveRequest {
    MoveRequest(
        window: window, spec: .named(.leftHalf), display: displayA.identity,
        placement: .leftHalf, cycleStep: 0, source: .action(.leftHalf)
    )
}

func display(_ visible: ScreenRect) -> Display {
    Display(
        identity: DisplayIdentity(name: "Test", vendor: 1, model: 2, serial: 3),
        frame: visible,
        visibleFrame: visible
    )
}

func namedDisplay(_ name: String, _ frame: ScreenRect, serial: UInt32 = 1) -> Display {
    Display(
        identity: DisplayIdentity(name: name, vendor: 7789, model: 30648, serial: serial),
        frame: frame,
        visibleFrame: frame
    )
}

let displayA = Display(
    identity: DisplayIdentity(name: "Built-in", vendor: 1, model: 1, serial: 1),
    frame: rect(0, 0, 1000, 800),
    visibleFrame: v
)

let displayB = Display(
    identity: DisplayIdentity(name: "Desk", vendor: 2, model: 2, serial: 2),
    frame: rect(1000, 0, 2000, 1550),
    visibleFrame: rect(1000, 0, 2000, 1550)
)

func window(
    _ id: UInt32,
    frame: ScreenRect,
    pid: Int32 = 100,
    bundleID: String = "com.example.app",
    appName: String = "Example"
) -> WindowSnapshot {
    WindowSnapshot(
        handle: WindowHandle(pid: pid, windowID: id, isStable: true),
        bundleID: bundleID,
        appName: appName,
        title: "Window \(id)",
        frame: frame,
        canMove: true,
        canResize: true,
        minSize: nil,
        isFullscreen: false,
        isSheet: false,
        isMinimized: false,
        isAppHidden: false
    )
}
