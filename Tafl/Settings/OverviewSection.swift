import AppKit
import SwiftUI
import TaflCore

struct OverviewSection: View {
    let model: SettingsModel
    let actions: SettingsActions

    private var issues: [String] {
        ConfigIssueLines.lines(status: .loaded, failures: model.activationFailures, layouts: model.config.layouts)
    }

    var body: some View {
        Form {
            Section("Config file") {
                LabeledContent("Path") {
                    Text((model.configPath as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                }
                LabeledContent("Status") { statusView }
                HStack {
                    Button("Open in Editor") { actions.openInEditor() }
                        .disabled(!model.fileExists)
                    Button("Reveal in Finder") { actions.revealInFinder() }
                        .disabled(!model.fileExists)
                    if !model.fileExists {
                        Button("Create Starter File") { actions.createStarterFile() }
                    }
                }
                if let error = model.starterFileError {
                    Text(error).foregroundStyle(.red)
                }
            }
            if !issues.isEmpty {
                Section("Shortcuts that could not be registered") {
                    ForEach(issues, id: \.self) { Text($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .defaults:
            Text("No file; using the built-in defaults")
        case .loaded:
            Text("Loaded")
        case .rejected(let error):
            VStack(alignment: .trailing, spacing: 2) {
                Text("Rejected: \(error.description)").foregroundStyle(.red)
                Text("Using the last good configuration").foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
    }
}
