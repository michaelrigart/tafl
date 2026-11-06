import ApplicationServices
import Testing
import TaflCore
@testable import TaflPlatform27

private func box(_ pid: pid_t) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(pid)) }
private let gone: Result<Int, AXFailure> = .failure(AXFailure(.invalidUIElement))

/// A failed read removes its own registration. Without the check, a replacement registered while the
/// read was in flight is removed with it, and later snapshots and writes find "no window".
@Test func aReadFoundGoneWithdrawsTheRegistrationItRead() async {
    let registry = WindowRegistry()
    let handle = registry.handle(for: box(10), pid: 10, windowID: ResolvedWindowID(id: 7, by: .privateSymbol))
    let result = await Platform27.readRegistered(handle, in: registry) { _ in gone }
    #expect(result == gone)
    #expect(registry.element(for: handle) == nil)
}

@Test func aReadFoundGoneLeavesAReplacementRegisteredMeanwhile() async {
    let registry = WindowRegistry()
    let exact = ResolvedWindowID(id: 7, by: .privateSymbol)
    let handle = registry.handle(for: box(10), pid: 10, windowID: exact)
    let replacement = AXElementBox(AXUIElementCreateSystemWide())
    let result = await Platform27.readRegistered(handle, in: registry) { read in
        #expect(read == box(10))
        _ = registry.handle(for: replacement, pid: 10, windowID: exact)
        return gone
    }
    #expect(result == gone)
    #expect(registry.element(for: handle) == replacement)
}

@Test func aReadOfAnUnregisteredHandleReadsNothing() async {
    let registry = WindowRegistry()
    let handle = WindowHandle(pid: 10, windowID: 7, isStable: true)
    let result = await Platform27.readRegistered(handle, in: registry) { _ -> Result<Int, AXFailure> in
        Issue.record("the read ran for an unregistered handle")
        return .success(1)
    }
    #expect(result == nil)
}

@Test func aReadThatFailsOtherwiseKeepsTheRegistration() async {
    let registry = WindowRegistry()
    let handle = registry.handle(for: box(10), pid: 10, windowID: ResolvedWindowID(id: 7, by: .privateSymbol))
    let timedOut: Result<Int, AXFailure> = .failure(AXFailure(.cannotComplete))
    let result = await Platform27.readRegistered(handle, in: registry) { _ in timedOut }
    #expect(result == timedOut)
    #expect(registry.element(for: handle) == box(10))
}
