import Foundation
import Testing
import TaflCore
@testable import TaflPlatform27

@Test func olderMacOSGetsThePlatformThatFailsEveryCall() async {
    let platform = PlatformFactory.make(osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0))
    #expect(platform is UnsupportedPlatform)
    #expect(await platform.displays().isEmpty)
    #expect(await platform.visibleWindows(take: { $0 }).isEmpty)
    #expect(await platform.appName(pid: 1) == nil)
    #expect(await platform.launchDates(of: [1]).isEmpty)
    #expect(await platform.focusedWindow(take: { $0 }) == .failure(.noWindow))
    #expect(await platform.snapshot(of: WindowHandle(pid: 1, windowID: 1, isStable: true), take: { $0 }) == .failure(.noWindow))
    #expect(await platform.startObserving(notices: RecordedNotices()).isEmpty)
    let capabilities = await platform.capabilities()
    #expect(capabilities.count == 1)
    #expect(capabilities.allSatisfy { !$0.isAvailable })
}

@Test func unsupportedPlatformRefusesToWrite() async {
    let platform = UnsupportedPlatform()
    let result = await platform.beginWriting(WindowHandle(pid: 1, windowID: 1, isStable: true))
    guard case .failure(.noWindow) = result else {
        Issue.record("expected .failure(.noWindow)")
        return
    }
    #expect(await !platform.isAccessibilityGranted())
    #expect(await platform.pointerDisplay() == nil)
    #expect(await platform.tilingSettings() == TilingSettings(edgeDrag: nil, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: nil))
}

/// pid_max is 99999, so this process never exists.
@Test func aProcessThatIsNotRunningHasNoLaunchDate() async {
    let platform = PlatformFactory.make(osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    #expect(await platform.launchDates(of: [999_999]).isEmpty)
}

@Test func macOS27AndLaterGetsTheRealPlatform() {
    let platform = PlatformFactory.make(osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    #expect(platform is Platform27)
}
