import ApplicationServices
import CoreGraphics
import Testing
@testable import TaflPlatform27

private let list: [WindowIDResolver.WindowListEntry] = [
    .init(pid: 42, id: 7, bounds: CGRect(x: 0, y: 25, width: 500, height: 775)),
    .init(pid: 42, id: 8, bounds: CGRect(x: 500, y: 25, width: 500, height: 775)),
]

@Test func windowListFallbackMatchesPIDAndBounds() {
    let element = AXUIElementCreateApplication(42)

    let matched = WindowIDResolver.windowID(
        element, pid: 42, frame: CGRect(x: 500, y: 25, width: 500, height: 775),
        privateLookup: { _ in nil }, windowList: { list })
    #expect(matched?.0 == 8)
    #expect(matched?.1 == .windowList)

    let unmatched = WindowIDResolver.windowID(
        element, pid: 42, frame: CGRect(x: 1, y: 25, width: 500, height: 775),
        privateLookup: { _ in nil }, windowList: { list })
    #expect(unmatched == nil)

    let otherPID = WindowIDResolver.windowID(
        element, pid: 43, frame: CGRect(x: 500, y: 25, width: 500, height: 775),
        privateLookup: { _ in nil }, windowList: { list })
    #expect(otherPID == nil)
}

@Test func privateSymbolWinsOverTheWindowList() {
    let element = AXUIElementCreateApplication(42)
    let resolved = WindowIDResolver.windowID(
        element, pid: 42, frame: CGRect(x: 500, y: 25, width: 500, height: 775),
        privateLookup: { _ in 99 }, windowList: { list })
    #expect(resolved?.0 == 99)
    #expect(resolved?.1 == .privateSymbol)
}

@Test func windowElementResolutionHandlesEmacs() {
    // Rectangle: a window is itself; else its containing window; else an element with the
    // AXStandardWindow subrole (Emacs 28 exposes its window as an AXTextField) is itself.
    #expect(AXWindowAccess.resolveWindowElement(1, isWindow: true, containingWindow: { 2 }, subrole: { nil }) == 1)
    #expect(AXWindowAccess.resolveWindowElement(1, isWindow: false, containingWindow: { 2 }, subrole: { nil }) == 2)
    #expect(AXWindowAccess.resolveWindowElement(1, isWindow: false, containingWindow: { nil }, subrole: { "AXStandardWindow" }) == 1)
    #expect(AXWindowAccess.resolveWindowElement(1, isWindow: false, containingWindow: { nil }, subrole: { "AXDialog" }) == nil)
}
