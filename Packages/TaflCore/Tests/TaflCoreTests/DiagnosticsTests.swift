import Testing
@testable import TaflCore

@Suite("Diagnostics")
struct DiagnosticsTests {
    private let capabilities = [
        CapabilityState(name: "Window identity", isAvailable: true, note: "Window ids come from macOS."),
        CapabilityState(name: "Other", isAvailable: false, note: "Falls back."),
    ]

    @Test func diagnosticsHasNoNames() {
        let status = ConfigStatus.rejected(
            ConfigError(line: 12, message: "unknown key \"Safari\" in /Users/michael/.config/tafl/config.toml"))
        let report = Diagnostics.report(
            macOS: "27.2.0", displayCount: 2, status: status, capabilities: capabilities,
            recentFailures: ["size-refused", "Safari didn't respond", "/Users/michael/Secret Plans.txt", "no-window"])
        #expect(!report.contains("Safari"))
        #expect(!report.contains("/Users"))
        #expect(!report.contains("Secret"))
        #expect(report.contains("size-refused"))
        #expect(report.contains("no-window"))
        #expect(report.contains("macOS: 27.2.0"))
        #expect(report.contains("Displays: 2"))
        #expect(report.contains("rejected at line 12"))
        #expect(report.contains("Window identity: available"))
        #expect(report.contains("Other: unavailable"))
    }

    @Test func statusKinds() {
        func config(_ status: ConfigStatus) -> String {
            Diagnostics.report(macOS: "27.0", displayCount: 1, status: status, capabilities: [], recentFailures: [])
        }
        #expect(config(.loaded).contains("Config: loaded"))
        #expect(config(.defaults).contains("Config: no file, using defaults"))
        #expect(config(.rejected(ConfigError(line: nil, message: "x"))).contains("Config: rejected\n"))
    }

    @Test func onlyTheLastTwentyFailuresAreReported() {
        let failures = (1...25).map { _ in "no-window" } + ["cannot-move"]
        let report = Diagnostics.report(
            macOS: "27.0", displayCount: 1, status: .loaded, capabilities: [], recentFailures: failures)
        #expect(report.components(separatedBy: "no-window").count - 1 == 19)
        #expect(report.contains("cannot-move"))
    }

    @Test func everyFailureCategoryIsKept() {
        let kinds: [FailureKind] = [
            .noWindow, .notResponding(app: "A"), .sizeRefused(app: "A"), .cannotMove, .fullscreen,
            .movedDuringPlacement, .noDisplayThatWay, .permissionMissing,
        ]
        let report = Diagnostics.report(
            macOS: "27.0", displayCount: 1, status: .loaded, capabilities: [], recentFailures: kinds.map(\.category))
        for kind in kinds { #expect(report.contains(kind.category), "\(kind.category)") }
    }
}
