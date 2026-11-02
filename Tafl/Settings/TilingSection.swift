import SwiftUI
import TaflCore

struct TilingSection: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("macOS drag tiling") {
                if let tiling = model.tiling {
                    LabeledContent("Drag to a screen edge") { Text(state(tiling.edgeDrag)) }
                    LabeledContent("Hold Option while dragging") { Text(state(tiling.optionAccelerator)) }
                    LabeledContent("Drag to the top edge to fill") { Text(state(tiling.topEdgeDrag)) }
                    LabeledContent("Margins around tiled windows") { Text(state(tiling.tiledMargins)) }
                } else {
                    Text("Reading the settings").foregroundStyle(.secondary)
                }
                if model.tiling?.tiledMargins == true {
                    Text("Set `gap` to match macOS's tiled-window margins for a consistent look.")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text("Dragging is left to macOS. Tafl never changes these settings.")
                    .foregroundStyle(.secondary)
                Button("Open Desktop & Dock Settings") { actions.openDesktopAndDockSettings() }
            }
        }
        .formStyle(.grouped)
    }

    private func state(_ value: Bool?) -> String {
        switch value {
        case true: "On"
        case false: "Off"
        case nil: "macOS default"
        }
    }
}
