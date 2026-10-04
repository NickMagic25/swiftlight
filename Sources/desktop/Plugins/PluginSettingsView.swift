#if os(macOS)
import SwiftUI
import SwiftlightHost
import SwiftlightPlugins
import UniformTypeIdentifiers

struct PluginSettingsView: View {
    @ObservedObject var manager: PluginManager
    let hosts: [SavedHost]
    @State private var source = ""
    @State private var choosingFile = false
    @State private var sourceError: String?

    var body: some View {
        Form {
            Section("Add a Plugin") {
                Text("Run your own actions when a Mac stream starts or ends. Import a YAML file, configure its fields, review its scripts, then enable it.")
                    .foregroundStyle(.secondary)
                TextField("File path or HTTPS URL", text: $source)
                    .textContentType(.URL)
                    .accessibilityHint("Accepts an absolute file path, a raw YAML URL, or a GitHub file page")
                    .onSubmit { importSource() }
                HStack {
                    Button("Choose YAML File…") { choosingFile = true }
                    Button("Import") { importSource() }
                        .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isImporting)
                    if manager.isImporting { ProgressView().controlSize(.small) }
                }
                if let error = sourceError ?? manager.error {
                    Text(error).foregroundStyle(.red).accessibilityLabel("Plugin error: " + error)
                }
                if let status = manager.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if manager.plugins.isEmpty {
                Section { Text("No plugins installed.").foregroundStyle(.secondary) }
            }
            ForEach(manager.plugins) { plugin in
                PluginConfigurationView(manager: manager, plugin: plugin)
            }
            if !hosts.isEmpty {
                Section("Computer Filters") {
                    Text("Use these computer IDs in a YAML hook’s host_id filter. Application IDs and names come from that computer’s application list.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(hosts) { host in
                        LabeledContent(host.name) { Text(host.id).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
            }
            Section {
                Text("Plugins can run code and access the information you provide. Enable only scripts you trust. Scripts inherit Swiftlight’s macOS sandbox; Python and Swift require an installed, accessible runtime. Refreshing a plugin disables it for review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "yaml") ?? .text, .text]) { result in
            switch result {
            case .success(let url):
                sourceError = nil
                Task { await manager.importPlugin(from: url) }
            case .failure: sourceError = "The selected file could not be opened."
            }
        }
    }

    private func importSource() {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        } else { url = URL(string: value) }
        guard let url, url.isFileURL || url.scheme?.lowercased() == "https" else {
            sourceError = "Choose a YAML file or enter an absolute file path or HTTPS URL."
            return
        }
        sourceError = nil
        Task { await manager.importPlugin(from: url) }
    }
}

private struct PluginConfigurationView: View {
    @ObservedObject var manager: PluginManager
    let plugin: InstalledPlugin
    @State private var values: [String: String]
    @State private var pythonExecutable: String
    @State private var swiftExecutable: String
    @State private var confirmingEnable = false
    @State private var saving = false

    init(manager: PluginManager, plugin: InstalledPlugin) {
        self.manager = manager
        self.plugin = plugin
        _values = State(initialValue: plugin.values)
        _pythonExecutable = State(initialValue: plugin.pythonExecutable)
        _swiftExecutable = State(initialValue: plugin.swiftExecutable)
    }

    var body: some View {
        Section(plugin.manifest.name) {
            if let description = plugin.manifest.description { Text(description).foregroundStyle(.secondary) }
            Text(plugin.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Toggle("Enabled", isOn: Binding(get: { plugin.enabled }, set: { enabled in
                if enabled && !hasUnsavedChanges { confirmingEnable = true }
                else { manager.setEnabled(pluginID: plugin.id, false) }
            }))
            .disabled(saving || manager.isBusy(pluginID: plugin.id) || (!plugin.enabled && hasUnsavedChanges))
            .accessibilityHint("Enabling permits this plugin’s scripts to run for matching streams")
            ForEach(plugin.manifest.fields, id: \.id) { field in
                fieldView(field)
                    .disabled(saving || manager.isBusy(pluginID: plugin.id))
                if let description = field.description { Text(description).font(.caption).foregroundStyle(.secondary) }
            }
            if plugin.manifest.hooks.contains(where: { $0.runtime == .python }) {
                TextField("Python executable", text: $pythonExecutable)
                    .disabled(saving || manager.isBusy(pluginID: plugin.id))
                    .help("Absolute path to a direct Python 3 executable accessible to the sandbox")
                Text("Use a direct Python interpreter. The /usr/bin/python3 developer-tool shim cannot run in App Sandbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if plugin.manifest.hooks.contains(where: { $0.runtime == .swift }) {
                TextField("Swift executable", text: $swiftExecutable)
                    .disabled(saving || manager.isBusy(pluginID: plugin.id))
                    .help("Absolute path to a direct Swift interpreter with an installed macOS SDK")
                Text("Use a direct Swift compiler from Xcode or Command Line Tools. The /usr/bin/swift shim cannot run in App Sandbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save Configuration") {
                    saving = true
                    Task {
                        _ = await manager.saveConfiguration(pluginID: plugin.id, values: values,
                            pythonExecutable: pythonExecutable, swiftExecutable: swiftExecutable)
                        saving = false
                    }
                }.disabled(saving || manager.isBusy(pluginID: plugin.id) || !hasUnsavedChanges)
                Button("Refresh") { Task { await manager.refreshPlugin(plugin.id) } }
                    .disabled(manager.isImporting || saving)
                Button("Remove", role: .destructive) { manager.removePlugin(plugin.id) }.disabled(saving)
            }
            if hasUnsavedChanges { Text("Save your changes before enabling this plugin.").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Review YAML and Scripts") {
                ScrollView([.horizontal, .vertical]) {
                    Text(plugin.manifestYAML).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 220).accessibilityLabel("Plugin YAML and scripts")
            }
            Text("Changes apply to the next stream. An active stream keeps its original start and end actions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Enable \(plugin.manifest.name)?", isPresented: $confirmingEnable) {
            Button("Enable") { manager.setEnabled(pluginID: plugin.id, true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permits the reviewed scripts to run automatically for matching streams, using your configured values and the computer and application identity. Enable only code you trust.")
        }
        .onChange(of: plugin.values) { _, new in values = new }
        .onChange(of: plugin.manifestYAML) { _, _ in
            values = plugin.values
            pythonExecutable = plugin.pythonExecutable
            swiftExecutable = plugin.swiftExecutable
        }
    }

    private var hasUnsavedChanges: Bool {
        values != plugin.values || pythonExecutable != plugin.pythonExecutable || swiftExecutable != plugin.swiftExecutable
    }

    @ViewBuilder private func fieldView(_ field: PluginField) -> some View {
        let label = field.label + (field.required ? " (required)" : "")
        switch field.type {
        case .boolean:
            Toggle(label, isOn: Binding(get: { value(field) == "true" }, set: { values[field.id] = $0 ? "true" : "false" }))
        case .choice:
            Picker(label, selection: binding(field)) {
                if !field.required || value(field).isEmpty { Text("Choose…").tag("") }
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
        case .secret: SecureField(label, text: binding(field))
        case .string, .integer: TextField(label, text: binding(field))
        }
    }

    private func value(_ field: PluginField) -> String { values[field.id] ?? field.defaultValue ?? "" }
    private func binding(_ field: PluginField) -> Binding<String> {
        Binding(get: { value(field) }, set: { values[field.id] = $0 })
    }
}
#endif
