import Testing
@testable import TaflCore

@Test func aLoadedConfigWithEveryShortcutBoundHasNoLines() {
    #expect(ConfigIssueLines.lines(status: .loaded, failures: [:], layouts: []).isEmpty)
    #expect(ConfigIssueLines.lines(status: .defaults, failures: [:], layouts: []).isEmpty)
}

@Test func aRejectedConfigShowsItsLineAndSaysTheLastGoodOneStays() {
    let status = ConfigStatus.rejected(ConfigError(line: 7, message: "unknown key \"gapp\""))
    #expect(ConfigIssueLines.lines(status: status, failures: [:], layouts: [])
        == ["Config rejected, using the last good one. Line 7: unknown key \"gapp\""])
    let noLine = ConfigStatus.rejected(ConfigError(line: nil, message: "config.toml points to a missing file"))
    #expect(ConfigIssueLines.lines(status: noLine, failures: [:], layouts: [])
        == ["Config rejected, using the last good one. config.toml points to a missing file"])
}

@Test func eachFailedShortcutNamesItsActionAndTheReason() {
    let failures: [HotkeyTarget: ActivationFailure] = [
        .action(.maximize): .taken,
        .action(.leftHalf): .clashes(with: .action(.rightHalf)),
        .layout("Desk"): .untranslatable("\"q\" isn't on the current keyboard layout"),
    ]
    let layouts = [LayoutDefinition(name: "Desk", displays: [], shortcut: nil, entries: [])]
    #expect(ConfigIssueLines.lines(status: .loaded, failures: failures, layouts: layouts) == [
        "Left half of the display: shortcut shares its keys with Right half of the display",
        "Fill the display: shortcut is taken by another app",
        "Layout Desk: \"q\" isn't on the current keyboard layout",
    ])
}

@Test func aRejectedConfigAndFailedShortcutsShowBoth() {
    let lines = ConfigIssueLines.lines(
        status: .rejected(ConfigError(line: 2, message: "bad")), failures: [.action(.center): .taken], layouts: [])
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("Config rejected"))
}
