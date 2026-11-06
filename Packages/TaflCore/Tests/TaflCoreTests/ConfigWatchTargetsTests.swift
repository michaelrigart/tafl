import Testing
@testable import TaflCore

private let configPath = "/h/.config/tafl/config.toml"

private func targets(_ links: [String: String]) -> [String] {
    ConfigWatchTargets.directories(configPath: configPath, readLink: { links[$0] })
}

@Test func aPlainFileWatchesItsDirectory() {
    #expect(targets([:]) == ["/h/.config/tafl"])
}

@Test func aLinkAlsoWatchesTheDirectoryOfItsTarget() {
    #expect(targets([configPath: "/h/dotfiles/tafl/config.toml"]) == ["/h/.config/tafl", "/h/dotfiles/tafl"])
}

@Test func aChainWatchesEveryDirectoryInOrder() {
    let links = [
        configPath: "/h/dotfiles/tafl/config.toml",
        "/h/dotfiles/tafl/config.toml": "/srv/shared/tafl.toml",
    ]
    #expect(targets(links) == ["/h/.config/tafl", "/h/dotfiles/tafl", "/srv/shared"])
}

@Test func aRelativeTargetResolvesAgainstTheLinksDirectory() {
    #expect(targets([configPath: "../../dotfiles/tafl/config.toml"]) == ["/h/.config/tafl", "/h/dotfiles/tafl"])
    #expect(targets([configPath: "real.toml"]) == ["/h/.config/tafl"])
}

@Test func aTargetInAnEarlierDirectoryIsNotListedTwice() {
    let links = [
        configPath: "/h/dotfiles/config.toml",
        "/h/dotfiles/config.toml": "/h/.config/tafl/real.toml",
    ]
    #expect(targets(links) == ["/h/.config/tafl", "/h/dotfiles"])
}

@Test func aLinkLoopEnds() {
    let links = [configPath: "/h/a/config.toml", "/h/a/config.toml": configPath]
    #expect(targets(links) == ["/h/.config/tafl", "/h/a"])
}
