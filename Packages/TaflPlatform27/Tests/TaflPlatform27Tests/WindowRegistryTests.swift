import ApplicationServices
import Testing
import TaflCore
@testable import TaflPlatform27

private func box(_ pid: pid_t) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(pid)) }

@Test func theSameElementKeepsItsHandle() async {
    let registry = WindowRegistry()
    let first = await registry.handle(for: box(10), pid: 10, windowID: 7)
    let again = await registry.handle(for: box(10), pid: 10, windowID: 7)
    #expect(first == WindowHandle(pid: 10, windowID: 7, isStable: true))
    #expect(again == first)
}

@Test func anElementKeepsItsHandleEvenWhenResolutionLaterDiffers() async {
    let registry = WindowRegistry()
    let first = await registry.handle(for: box(10), pid: 10, windowID: nil)
    let again = await registry.handle(for: box(10), pid: 10, windowID: 99)
    #expect(again == first)
}

@Test func anUnresolvedWindowGetsAnUnstableHandleThatStaysTheSame() async {
    let registry = WindowRegistry()
    let first = await registry.handle(for: box(10), pid: 10, windowID: nil)
    let other = await registry.handle(for: box(11), pid: 11, windowID: nil)
    let again = await registry.handle(for: box(10), pid: 10, windowID: nil)
    #expect(!first.isStable)
    #expect(first.pid == 10)
    #expect(again == first)
    #expect(other != first)
}

@Test func syntheticHandlesAreNeverEqualToResolvedOnes() async {
    let registry = WindowRegistry()
    let synthetic = await registry.handle(for: box(10), pid: 10, windowID: nil)
    let resolved = await registry.handle(for: box(11), pid: 10, windowID: synthetic.windowID)
    #expect(resolved != synthetic)
    #expect(resolved.isStable)
}

@Test func aHandleLeadsBackToItsElementAndAnElementToItsHandle() async {
    let registry = WindowRegistry()
    let handle = await registry.handle(for: box(10), pid: 10, windowID: 7)
    #expect(await registry.element(for: handle) == box(10))
    #expect(await registry.knownHandle(of: box(10)) == handle)
    #expect(await registry.knownHandle(of: box(11)) == nil)
}

@Test func aRecreatedElementWithTheSameWindowIDReplacesTheOldOne() async {
    let registry = WindowRegistry()
    let old = AXElementBox(AXUIElementCreateApplication(10))
    let handle = await registry.handle(for: old, pid: 10, windowID: 7)
    let renewed = AXElementBox(AXUIElementCreateSystemWide())
    let again = await registry.handle(for: renewed, pid: 10, windowID: 7)
    #expect(again == handle)
    #expect(await registry.element(for: handle) == renewed)
    #expect(await registry.knownHandle(of: old) == nil)
}

@Test func destroyedWindowsAndQuitAppsAreDropped() async {
    let registry = WindowRegistry()
    let gone = await registry.handle(for: box(10), pid: 10, windowID: 7)
    let kept = await registry.handle(for: box(11), pid: 11, windowID: 8)
    await registry.remove(gone)
    #expect(await registry.element(for: gone) == nil)
    #expect(await registry.element(for: kept) != nil)

    _ = await registry.handle(for: box(11), pid: 11, windowID: 9)
    await registry.removeApp(pid: 11)
    #expect(await registry.element(for: kept) == nil)
    #expect(await registry.count == 0)
}
