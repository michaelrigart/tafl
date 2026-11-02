import SwiftUI
import TaflCore

struct ShortcutsSection: View {
    let model: SettingsModel

    private static let groups: [(title: String, actions: [Action])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Thirds", [.firstThird, .centerThird, .lastThird]),
        ("Two thirds", [.firstTwoThirds, .centerTwoThirds, .lastTwoThirds]),
        ("Size and position", [.maximize, .maximizeHeight, .center, .restore, .larger, .smaller]),
        ("Displays", [.displayLeft, .displayRight, .displayUp, .displayDown, .displayUnderPointer]),
    ]

    private var groups: [(title: String, actions: [Action])] {
        let listed = Set(Self.groups.flatMap(\.actions))
        let rest = Action.allCases.filter { !listed.contains($0) }
        return rest.isEmpty ? Self.groups : Self.groups + [("Other", rest)]
    }

    var body: some View {
        Form {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.actions, id: \.self) { action in
                        row(action)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: Action) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(action.summary) {
                Text(model.shortcutText(for: action))
                    .font(.body.monospaced())
                    .foregroundStyle(model.config.binding(for: action) == .unbound ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            if let failure = model.activationFailures[.action(action)] {
                Text(failure.settingsText).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
