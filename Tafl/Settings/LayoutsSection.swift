import SwiftUI
import TaflCore

struct LayoutsSection: View {
    @ObservedObject var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            ForEach(model.config.layouts, id: \.name) { layout in
                Section {
                    triggers(layout)
                    ForEach(Array(layout.entries.enumerated()), id: \.offset) { _, entry in
                        Text(describe(entry)).font(.callout)
                    }
                    if layout.entries.isEmpty {
                        Text("No window entries").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(layout.name)
                        if layout.name == model.activeLayout {
                            Text("Active").font(.caption.bold()).foregroundStyle(.green)
                        }
                    }
                }
            }
            if model.config.layouts.isEmpty {
                Section {
                    Text("No layouts in the config file. Capture the current arrangement to get a start.")
                        .foregroundStyle(.secondary)
                }
            }
            captureSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func triggers(_ layout: LayoutDefinition) -> some View {
        if !layout.displays.isEmpty {
            LabeledContent("Applies when exactly these are connected") {
                Text(layout.displays.joined(separator: ", ")).textSelection(.enabled)
            }
        }
        if let shortcut = layout.shortcut {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Shortcut") {
                    Text(shortcut.text).font(.body.monospaced()).textSelection(.enabled)
                }
                if let failure = model.activationFailures[.layout(layout.name)] {
                    Text(failure.settingsText).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func describe(_ entry: LayoutEntry) -> String {
        var text = entry.app
        if let title = entry.title { text += " titled \"\(title)\"" }
        text += ": \(entry.place.rawValue)"
        if let display = entry.display { text += " on \(display)" }
        return text
    }

    private var captureSection: some View {
        Section("Capture Current Arrangement") {
            Text("Builds a layout from the windows on this Space that sit in a recognised placement, and copies it. Paste it into the config file.")
                .foregroundStyle(.secondary)
            Button("Capture Current Arrangement") { Task { await actions.capture() } }
            if let note = model.captureNote {
                Text(note).foregroundStyle(.orange)
            }
            if let snippet = model.capturedSnippet {
                ScrollView {
                    Text(snippet)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 220)
                Button("Copy Again") { actions.copyCaptured() }
                Text("Copied to the clipboard").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
