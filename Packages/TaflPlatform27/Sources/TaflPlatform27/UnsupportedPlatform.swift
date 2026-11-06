import Foundation
import TaflCore

/// The platform on a macOS older than 27: every call fails or answers empty, and the one
/// capability says why.
final class UnsupportedPlatform: WindowPlatform {
    static let capabilityNote = "Tafl needs macOS 27 or later."

    let events: AsyncStream<PlatformEvent>

    init() {
        events = AsyncStream<PlatformEvent>.makeStream(bufferingPolicy: .unbounded).stream
    }

    func displays() async -> [Display] { [] }
    func focusedWindow<T: Sendable>(take: @escaping @Sendable (WindowSnapshot) -> T) async -> Result<T, PlatformFailure> {
        .failure(.noWindow)
    }
    func visibleWindows<T: Sendable>(take: @escaping @Sendable (WindowSnapshot) -> T) async -> [T] { [] }
    func snapshot<T: Sendable>(
        of handle: WindowHandle,
        take: @escaping @Sendable (WindowSnapshot) -> T
    ) async -> Result<T, PlatformFailure> {
        .failure(.noWindow)
    }
    func appName(pid: Int32) async -> String? { nil }
    func launchDates(of pids: Set<Int32>) async -> [Int32: Date] { [:] }
    func beginWriting(_ handle: WindowHandle) async -> Result<any WriteSession, PlatformFailure> { .failure(.noWindow) }
    func pointerDisplay() async -> DisplayIdentity? { nil }
    func tilingSettings() async -> TilingSettings {
        TilingSettings(edgeDrag: nil, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: nil)
    }
    func isAccessibilityGranted() async -> Bool { false }
    func capabilities() async -> [CapabilityState] {
        [CapabilityState(name: "macOS version", isAvailable: false, note: Self.capabilityNote)]
    }
    func startObserving() async -> [UnobservableApp] { [] }
    func stopObserving() async {}
}
