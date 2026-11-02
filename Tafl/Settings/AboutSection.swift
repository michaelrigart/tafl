import SwiftUI

struct AboutSection: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Tafl") {
                LabeledContent("Version") { Text(version).textSelection(.enabled) }
            }
            Section("Capabilities") {
                if model.capabilities.isEmpty {
                    Text("Reading the capabilities").foregroundStyle(.secondary)
                }
                ForEach(model.capabilities, id: \.name) { capability in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(capability.name) {
                            Text(capability.isAvailable ? "Available" : "Unavailable")
                                .foregroundStyle(capability.isAvailable ? .green : .orange)
                        }
                        Text(capability.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Diagnostics") {
                Text("The macOS version, the number of displays, the config status, the capabilities above and recent failure categories. No app names, window titles or paths.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Copy Diagnostics") { Task { await actions.copyDiagnostics() } }
                    if model.diagnosticsCopied {
                        Text("Copied to the clipboard").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
