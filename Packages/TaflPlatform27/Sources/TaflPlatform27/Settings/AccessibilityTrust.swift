import ApplicationServices
import Darwin
import TaflCore

/// The Accessibility grant as tccd answers it. `AXIsProcessTrusted()` caches its answer in the process
/// and refills the cache before macOS stores a change, so it keeps the old value after a switch in
/// System Settings. `TCCAccessPreflight` asks tccd on every call.
enum AccessibilityTrust {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32

    private static let frameworkPath = "/System/Library/PrivateFrameworks/TCC.framework/TCC"

    /// `TCCAccessPreflight`, or nil when the framework or the symbol is missing.
    private static let preflight: Preflight? = {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else { return nil }
        return resolve(symbol: dlsym(handle, "TCCAccessPreflight"))
    }()

    static var preflightAvailable: Bool { preflight != nil }

    static func resolve(symbol: UnsafeMutableRawPointer?) -> Preflight? {
        symbol.map { unsafeBitCast($0, to: Preflight.self) }
    }

    /// 0 is granted; 1 is denied and 2 unknown (never asked), and any other value is no grant either.
    static func isTrusted(preflightResult: Int32) -> Bool { preflightResult == 0 }

    static func read(preflight: Preflight?, fallback: () -> Bool) -> Bool {
        guard let preflight else { return fallback() }
        return isTrusted(preflightResult: preflight("kTCCServiceAccessibility" as CFString, nil))
    }

    static func read() -> Bool {
        read(preflight: preflight, fallback: { AXIsProcessTrusted() })
    }

    static func capability(preflightAvailable: Bool) -> CapabilityState {
        let name = "Accessibility check"
        if preflightAvailable {
            return CapabilityState(name: name, isAvailable: true, note: "The permission is read from macOS each time.")
        }
        return CapabilityState(
            name: name, isAvailable: true,
            note: "The permission is read from the app's cached answer, so a change in System Settings can take until the next restart to show.")
    }
}
