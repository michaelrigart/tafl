import ApplicationServices
import CoreGraphics
import Testing
import TaflCore
@testable import TaflPlatform27

private let handle = WindowHandle(pid: 10, windowID: 7, isStable: true)
private let app = AppInfo27(pid: 10, bundleID: "com.example.App", name: "Example", isHidden: false)

private func attributes(
    role: String? = "AXWindow",
    subrole: String? = "AXStandardWindow",
    isMinimized: Bool = false,
    isFullscreen: Bool = false
) -> WindowAttributes27 {
    WindowAttributes27(
        role: role, subrole: subrole, title: "Doc", frame: CGRect(x: 10, y: 20, width: 300, height: 200),
        canMove: true, canResize: false, minSize: CGSize(width: 100, height: 50),
        isFullscreen: isFullscreen, isMinimized: isMinimized)
}

@Test func aStandardWindowBecomesASnapshotWithEveryField() {
    let snapshot = Windows27.snapshot(handle: handle, app: app, attributes: attributes())
    #expect(snapshot == WindowSnapshot(
        handle: handle, bundleID: "com.example.App", appName: "Example", title: "Doc",
        frame: ScreenRect(x: 10, y: 20, width: 300, height: 200),
        canMove: true, canResize: false, minSize: ScreenSize(width: 100, height: 50),
        isFullscreen: false, isSheet: false, isMinimized: false, isAppHidden: false))
}

@Test func aSheetIsKeptAndFlagged() {
    let bySubrole = Windows27.snapshot(handle: handle, app: app, attributes: attributes(subrole: "AXSheet"))
    let byRole = Windows27.snapshot(handle: handle, app: app, attributes: attributes(role: "AXSheet", subrole: nil))
    #expect(bySubrole?.isSheet == true)
    #expect(byRole?.isSheet == true)
    #expect(bySubrole?.isPlaceable == false)
}

@Test func windowsThatAreNeitherStandardNorSheetsAreLeftOut() {
    for subrole in ["AXDialog", "AXFloatingWindow", "AXSystemDialog", "AXSystemFloatingWindow", nil] {
        #expect(Windows27.snapshot(handle: handle, app: app, attributes: attributes(subrole: subrole)) == nil, "\(String(describing: subrole))")
    }
}

@Test func minimizedFullscreenAndHiddenAppFlagsComeThrough() {
    let minimized = Windows27.snapshot(handle: handle, app: app, attributes: attributes(isMinimized: true))
    let fullscreen = Windows27.snapshot(handle: handle, app: app, attributes: attributes(isFullscreen: true))
    let hiddenApp = AppInfo27(pid: 10, bundleID: nil, name: "Example", isHidden: true)
    let hidden = Windows27.snapshot(handle: handle, app: hiddenApp, attributes: attributes())
    #expect(minimized?.isMinimized == true)
    #expect(fullscreen?.isFullscreen == true)
    #expect(hidden?.isAppHidden == true)
    #expect(hidden?.bundleID == nil)
    #expect(hidden?.isPlaceable == false)
}

@Test func anAppWithoutAMinimumSizeGivesNone() {
    var raw = attributes()
    raw.minSize = nil
    #expect(Windows27.snapshot(handle: handle, app: app, attributes: raw)?.minSize == nil)
}

@Test func accessibilityErrorsMapToTheContractsFailures() {
    #expect(Windows27.failure(for: .cannotComplete) == .notResponding)
    #expect(Windows27.failure(for: .invalidUIElement) == .noWindow)
    #expect(Windows27.failure(for: .noValue) == .noWindow)
    #expect(Windows27.failure(for: .attributeUnsupported) == .noWindow)
}

@Test func aFailedPositionWriteIsFullscreenCannotMoveOrNotRespondingByCause() {
    #expect(Windows27.positionFailure(for: .cannotComplete, isFullscreen: { false }) == .notResponding)
    #expect(Windows27.positionFailure(for: .invalidUIElement, isFullscreen: { false }) == .noWindow)
    #expect(Windows27.positionFailure(for: .failure, isFullscreen: { false }) == .cannotMove)
    #expect(Windows27.positionFailure(for: .failure, isFullscreen: { true }) == .fullscreen)
}

@Test func aRefusedSizeIsLeftToTheCoresReadBack() {
    #expect(Windows27.sizeFailure(for: .success) == nil)
    #expect(Windows27.sizeFailure(for: .failure) == nil)
    #expect(Windows27.sizeFailure(for: .attributeUnsupported) == nil)
    #expect(Windows27.sizeFailure(for: .cannotComplete) == .notResponding)
    #expect(Windows27.sizeFailure(for: .invalidUIElement) == .noWindow)
}

@Test func windowIdentityCapabilityNamesItsSource() {
    let direct = Platform27.windowIdentityCapability(privateSymbol: true, windowList: true)
    let fallback = Platform27.windowIdentityCapability(privateSymbol: false, windowList: true)
    let none = Platform27.windowIdentityCapability(privateSymbol: false, windowList: false)
    #expect(direct.isAvailable && fallback.isAvailable && !none.isAvailable)
    #expect(Set([direct.note, fallback.note, none.note]).count == 3)
    #expect(direct.name == fallback.name && fallback.name == none.name)
}
