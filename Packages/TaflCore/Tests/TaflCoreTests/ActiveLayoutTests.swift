import Testing
@testable import TaflCore

struct ActiveLayoutTests {
    private func config(_ names: [String], terminalPlace: NamedPlacement = .firstThird) -> Config {
        Config(
            shortcuts: [:], repeatMode: .displays, gap: 0, step: 30, menuBarIcon: true, launchAtLogin: true,
            layouts: names.map {
                LayoutDefinition(
                    name: $0, displays: [], shortcut: nil,
                    entries: [LayoutEntry(app: "com.apple.Terminal", title: nil, place: terminalPlace, display: nil)]
                )
            }
        )
    }

    @Test func reloadReconciles() {
        var active = ActiveLayout()
        active.activate("Desk")
        #expect(active.definition(in: config(["Desk"]))?.name == "Desk")

        let edited = config(["Desk"], terminalPlace: .lastThird)
        active.reconcile(with: edited)
        #expect(active.name == "Desk")
        #expect(active.definition(in: edited)?.entries.first?.place == .lastThird)

        active.reconcile(with: config(["Desk", "Travel"]))
        #expect(active.name == "Desk")

        active.reconcile(with: config(["Travel"]))
        #expect(active.name == nil)
        #expect(active.definition(in: config(["Desk"])) == nil)
    }

    @Test func renamedLayoutEnds() {
        var active = ActiveLayout()
        active.activate("Desk")
        active.reconcile(with: config(["Desk 2"]))
        #expect(active.name == nil)
    }

    @Test func nameComparisonIsExact() {
        var active = ActiveLayout()
        active.activate("Desk")
        active.reconcile(with: config(["desk"]))
        #expect(active.name == nil)
    }

    @Test func displayChangeEnds() {
        var active = ActiveLayout()
        active.activate("Desk")
        active.endForDisplayChange()
        #expect(active.name == nil)
    }

    @Test func activatingAnotherReplaces() {
        var active = ActiveLayout()
        active.activate("Desk")
        active.activate("Travel")
        #expect(active.name == "Travel")
    }

    @Test func nothingActiveHasNoDefinition() {
        #expect(ActiveLayout().definition(in: config(["Desk"])) == nil)
    }
}
