import ApplicationServices
import Testing
import TaflCore
@testable import TaflPlatform27

private func box(_ pid: pid_t) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(pid)) }

/// A handle with no registration has no element to read: the read never runs.
@Test func aReadOfAnUnregisteredHandleReadsNothing() async {
    let registry = WindowRegistry()
    let handle = WindowHandle(pid: 10, windowID: 7, isStable: true)
    let result = await Platform27.readRegistered(handle, registry: registry) { _ -> Result<Int, AXFailure> in
        Issue.record("the read ran for an unregistered handle")
        return .success(1)
    }
    #expect(result == nil)
}

/// Around a wake every read of a live window fails as invalid for about 2 s. The read fails, and the
/// window stays registered and its owner untold, so the next read of it works. A read that timed out
/// is kept the same way.
@Test(arguments: [AXError.invalidUIElement, .cannotComplete])
func aFailedReadKeepsTheWindowForTheNextRead(_ code: AXError) async {
    let harness = EndsHarness()
    let registry = harness.registry
    let handle = registry.handle(for: box(10), pid: 10, windowID: ResolvedWindowID(id: 7, by: .privateSymbol))
    let failure: Result<Int, AXFailure> = .failure(AXFailure(code))
    let failed = await Platform27.readRegistered(handle, registry: registry) { _ in failure }
    #expect(failed == failure)
    #expect(registry.element(for: handle) == box(10))
    #expect(harness.notices.all.isEmpty)
    let later = await Platform27.readRegistered(handle, registry: registry) { read -> Result<Int, AXFailure> in
        #expect(read == box(10))
        return .success(5)
    }
    #expect(later == .success(5))
    #expect(harness.notices.all.isEmpty)
}
