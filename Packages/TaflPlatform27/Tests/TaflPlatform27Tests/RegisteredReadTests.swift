import ApplicationServices
import Testing
import TaflCore
@testable import TaflPlatform27

private func box(_ pid: pid_t) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(pid)) }
private let gone: Result<Int, AXFailure> = .failure(AXFailure(.invalidUIElement))

/// A read that finds the element invalid removes its own registration, and the window ends.
@Test func aReadFoundGoneWithdrawsTheRegistrationItRead() async {
    let harness = EndsHarness()
    let registry = harness.registry
    let handle = registry.handle(for: box(10), pid: 10, windowID: ResolvedWindowID(id: 7, by: .privateSymbol))
    let result = await Platform27.readRegistered(handle, ends: harness.ends) { _ in gone }
    #expect(result == gone)
    #expect(registry.element(for: handle) == nil)
    #expect(harness.notices.all == [.destroyed(handle)])
}

/// Only the pair the read used is withdrawn. Without the check, a replacement registered while the
/// read was in flight is removed with it, and later snapshots and writes find "no window".
@Test func aReadFoundGoneLeavesAReplacementRegisteredMeanwhile() async {
    let harness = EndsHarness()
    let registry = harness.registry
    let exact = ResolvedWindowID(id: 7, by: .privateSymbol)
    let handle = registry.handle(for: box(10), pid: 10, windowID: exact)
    let replacement = AXElementBox(AXUIElementCreateSystemWide())
    let result = await Platform27.readRegistered(handle, ends: harness.ends) { read in
        #expect(read == box(10))
        _ = registry.handle(for: replacement, pid: 10, windowID: exact)
        return gone
    }
    #expect(result == gone)
    #expect(registry.element(for: handle) == replacement)
    #expect(harness.notices.all.isEmpty)
}

/// A handle with no registration has no element to read: the read never runs.
@Test func aReadOfAnUnregisteredHandleReadsNothing() async {
    let harness = EndsHarness()
    let handle = WindowHandle(pid: 10, windowID: 7, isStable: true)
    let result = await Platform27.readRegistered(handle, ends: harness.ends) { _ -> Result<Int, AXFailure> in
        Issue.record("the read ran for an unregistered handle")
        return .success(1)
    }
    #expect(result == nil)
}

/// Only an invalid element means the window is gone: a read that timed out keeps the registration.
@Test func aReadThatFailsOtherwiseKeepsTheRegistration() async {
    let harness = EndsHarness()
    let registry = harness.registry
    let handle = registry.handle(for: box(10), pid: 10, windowID: ResolvedWindowID(id: 7, by: .privateSymbol))
    let timedOut: Result<Int, AXFailure> = .failure(AXFailure(.cannotComplete))
    let result = await Platform27.readRegistered(handle, ends: harness.ends) { _ in timedOut }
    #expect(result == timedOut)
    #expect(registry.element(for: handle) == box(10))
    #expect(harness.notices.all.isEmpty)
}
