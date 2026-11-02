import SwiftUI
import TaflCore

struct DisplaysSection: View {
    @ObservedObject var model: SettingsModel

    private var claiming: LayoutDefinition? {
        LayoutPlanner.claiming(model.config.layouts, displays: model.displays)
    }

    var body: some View {
        Form {
            Section("Connected displays") {
                if model.displays.isEmpty {
                    Text("No displays found").foregroundStyle(.secondary)
                }
                ForEach(model.displays, id: \.identity) { display in
                    row(display)
                }
            }
            Section("Current setup") {
                if let claiming {
                    LabeledContent("Claimed by layout") { Text(claiming.name) }
                } else {
                    Text("No layout claims the displays connected now").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ display: Display) -> some View {
        let reference = DisplayMatcher.reference(for: display, among: model.displays)
        let repeated = reference != display.identity.name
        return VStack(alignment: .leading, spacing: 2) {
            LabeledContent(display.identity.name) {
                Text(reference).font(.body.monospaced()).textSelection(.enabled)
            }
            if repeated {
                Text("Another display has the same name, so use this identifier in the config file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
