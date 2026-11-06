import ApplicationServices
import CoreGraphics
import Testing
import TaflCore
@testable import TaflPlatform27

private let handle = WindowHandle(pid: 10, windowID: 7, isStable: true)
private let app = AppInfo27(pid: 10, bundleID: "com.example.App", name: "Example", isHidden: false)
private let readAt = ContinuousClock.now

private func attributes(
    role: String? = "AXWindow",
    subrole: String? = "AXStandardWindow",
    isMinimized: Bool = false,
    isFullscreen: Bool = false
) -> WindowAttributes27 {
    WindowAttributes27(
        role: role, subrole: subrole, title: "Doc", frame: CGRect(x: 10, y: 20, width: 300, height: 200),
        canMove: true, canResize: false, minSize: CGSize(width: 100, height: 50),
        isFullscreen: isFullscreen, isMinimized: isMinimized, readAt: readAt)
}

// The snapshot carries when its frame was read, not when it was made.
@Test func aStandardWindowBecomesASnapshotWithEveryField() {
    let snapshot = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes())
    #expect(snapshot == WindowSnapshot(
        handle: handle, bundleID: "com.example.App", appName: "Example", title: "Doc",
        frame: ScreenRect(x: 10, y: 20, width: 300, height: 200),
        canMove: true, canResize: false, minSize: ScreenSize(width: 100, height: 50),
        isFullscreen: false, isSheet: false, isMinimized: false, isAppHidden: false, readAt: readAt))
}

@Test func aSheetIsKeptAndFlagged() {
    let bySubrole = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(subrole: "AXSheet"))
    let byRole = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(role: "AXSheet", subrole: nil))
    #expect(bySubrole?.isSheet == true)
    #expect(byRole?.isSheet == true)
    #expect(bySubrole?.isPlaceable == false)
}

@Test func windowsThatAreNeitherStandardNorSheetsAreLeftOut() {
    for subrole in ["AXDialog", "AXFloatingWindow", "AXSystemDialog", "AXSystemFloatingWindow", nil] {
        #expect(Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(subrole: subrole)) == nil, "\(String(describing: subrole))")
    }
}

@Test func minimizedFullscreenAndHiddenAppFlagsComeThrough() {
    let minimized = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(isMinimized: true))
    let fullscreen = Windows27.trackedSnapshot(handle: handle, app: app, attributes: attributes(isFullscreen: true))
    let hiddenApp = AppInfo27(pid: 10, bundleID: nil, name: "Example", isHidden: true)
    let hidden = Windows27.trackedSnapshot(handle: handle, app: hiddenApp, attributes: attributes())
    #expect(minimized?.isMinimized == true)
    #expect(fullscreen?.isFullscreen == true)
    #expect(hidden?.isAppHidden == true)
    #expect(hidden?.bundleID == nil)
    #expect(hidden?.isPlaceable == false)
}

@Test func anAppWithoutAMinimumSizeGivesNone() {
    var raw = attributes()
    raw.minSize = nil
    #expect(Windows27.trackedSnapshot(handle: handle, app: app, attributes: raw)?.minSize == nil)
}

@Test func accessibilityErrorsMapToTheContractsFailures() {
    #expect(Windows27.failure(for: .cannotComplete) == .notResponding)
    #expect(Windows27.failure(for: .invalidUIElement) == .noWindow)
    #expect(Windows27.failure(for: .noValue) == .noWindow)
    #expect(Windows27.failure(for: .attributeUnsupported) == .noWindow)
}

@Test func theFocusedPathKeepsDialogsPalettesAndWindowsWithoutASubrole() {
    for subrole in ["AXDialog", "AXFloatingWindow", "AXSystemFloatingWindow", nil] {
        let snapshot = Windows27.snapshot(handle: handle, app: app, attributes: attributes(subrole: subrole))
        #expect(snapshot.handle == handle, "\(String(describing: subrole))")
        #expect(!snapshot.isSheet)
    }
}

@Test func theFocusedPathStillFlagsSheets() {
    #expect(Windows27.snapshot(handle: handle, app: app, attributes: attributes(subrole: "AXSheet")).isSheet)
}

@Test func aSystemDialogIsNeverResizable() {
    var raw = attributes(subrole: "AXSystemDialog")
    raw.canResize = true
    #expect(!Windows27.snapshot(handle: handle, app: app, attributes: raw).canResize)
    raw.subrole = "AXDialog"
    #expect(Windows27.snapshot(handle: handle, app: app, attributes: raw).canResize)
}

@Test func aFailedPositionWriteIsFullscreenCannotMoveOrNotRespondingByCause() {
    #expect(Windows27.positionFailure(for: .cannotComplete, isFullscreen: { false }) == .notResponding)
    #expect(Windows27.positionFailure(for: .invalidUIElement, isFullscreen: { false }) == .noWindow)
    #expect(Windows27.positionFailure(for: .failure, isFullscreen: { false }) == .cannotMove)
    #expect(Windows27.positionFailure(for: .failure, isFullscreen: { true }) == .fullscreen)
}

private func position(
    settable: Result<Bool, AXFailure>, write: AXError = .success, fullscreen: Bool = false
) -> (failure: PlatformFailure?, wrote: Bool) {
    var wrote = false
    let result = Windows27.writePosition(
        settable: { settable }, write: { wrote = true; return write }, isFullscreen: { fullscreen })
    if case .failure(let failure) = result { return (failure, wrote) }
    return (nil, wrote)
}

private func lookUp(
    focused: () -> Result<Int, AXFailure>, first: () -> Result<Int?, AXFailure>, systemWide: () -> Int?
) -> Result<Int, AXFailure> {
    AXWindowAccess.lookUpFocusedWindow(focused: focused, first: first, systemWide: systemWide)
}

@Test func aTimeoutReadingSettabilityIsNotRespondingNotCannotMove() {
    let outcome = position(settable: .failure(AXFailure(.cannotComplete)))
    #expect(outcome.failure == .notResponding)
    #expect(!outcome.wrote)
}

@Test func aTimeoutWritingThePositionIsNotResponding() {
    let outcome = position(settable: .success(true), write: .cannotComplete)
    #expect(outcome.failure == .notResponding)
    #expect(outcome.wrote)
}

@Test func aDestroyedWindowIsNoWindowAtEitherStep() {
    #expect(position(settable: .failure(AXFailure(.invalidUIElement))).failure == .noWindow)
    #expect(position(settable: .success(true), write: .invalidUIElement).failure == .noWindow)
}

@Test func aGenuineRefusalIsFullscreenOrCannotMove() {
    let unsettable = position(settable: .success(false))
    #expect(unsettable.failure == .cannotMove)
    #expect(!unsettable.wrote)
    #expect(position(settable: .success(false), fullscreen: true).failure == .fullscreen)
    #expect(position(settable: .success(true), write: .failure).failure == .cannotMove)
    #expect(position(settable: .success(true), write: .failure, fullscreen: true).failure == .fullscreen)
}

@Test func aSettableWindowIsWritten() {
    let outcome = position(settable: .success(true))
    #expect(outcome.failure == nil)
    #expect(outcome.wrote)
}

@Test func aSettabilityFailureOtherThanATimeoutIsARefusal() {
    #expect(position(settable: .failure(AXFailure(.attributeUnsupported))).failure == .cannotMove)
}

@Test func theFocusedLookupStopsAtTheFirstTimeout() {
    var calls: [String] = []
    let result = lookUp(
        focused: { calls.append("focused"); return .failure(AXFailure(.cannotComplete)) },
        first: { calls.append("first"); return .success(1) },
        systemWide: { calls.append("systemWide"); return 2 })
    #expect(result == .failure(AXFailure(.cannotComplete)))
    #expect(calls == ["focused"])
}

@Test func theFocusedLookupStopsAtATimeoutInTheWindowList() {
    var calls: [String] = []
    let result = lookUp(
        focused: { calls.append("focused"); return .failure(AXFailure(.noValue)) },
        first: { calls.append("first"); return .failure(AXFailure(.cannotComplete)) },
        systemWide: { calls.append("systemWide"); return 2 })
    #expect(result == .failure(AXFailure(.cannotComplete)))
    #expect(calls == ["focused", "first"])
}

@Test func theFocusedLookupFallsThroughOrdinaryFailuresInOrder() {
    #expect(lookUp(
        focused: { .failure(AXFailure(.noValue)) }, first: { .success(1) }, systemWide: { 2 }) == .success(1))
    #expect(lookUp(
        focused: { .failure(AXFailure(.noValue)) }, first: { .success(nil) }, systemWide: { 2 }) == .success(2))
    #expect(lookUp(
        focused: { .failure(AXFailure(.noValue)) }, first: { .success(nil) }, systemWide: { Int?.none }) == .failure(AXFailure(.noValue)))
    #expect(lookUp(
        focused: { .success(0) }, first: { .success(1) }, systemWide: { 2 }) == .success(0))
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
