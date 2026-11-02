import SwiftUI

struct PermissionsSection: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("Accessibility") {
                LabeledContent("State") {
                    Text(model.trusted ? "Granted" : "Not granted")
                        .foregroundStyle(model.trusted ? .green : .orange)
                }
                Text("Tafl moves and resizes windows through Accessibility. It asks for nothing else.")
                    .foregroundStyle(.secondary)
                if !model.trusted {
                    Button("Grant Accessibility Access") { actions.openAccessibilitySettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
