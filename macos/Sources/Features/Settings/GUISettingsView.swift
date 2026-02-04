import SwiftUI
import GhosttyKit

/// Field type for config options
enum ConfigFieldType: Int {
    case string = 0
    case boolean = 1
    case option = 2
}

/// A single config metadata entry
struct ConfigMetadataItem: Identifiable {
    let id: Int
    let name: String
    let fieldType: ConfigFieldType
    let options: [String]
}

/// View model that loads config metadata from the C API and persists changes
/// through ``SettingsStore``. Changes are staged locally and only applied
/// when the user clicks "Apply".
class ConfigMetadataViewModel: ObservableObject {
    @Published var items: [ConfigMetadataItem] = []
    @Published var searchText: String = ""
    @Published var values: [String: String] = [:]
    @Published var errors: [String] = []

    /// Tracks which keys the user has modified in this session so we can
    /// visually distinguish overridden values.
    @Published var modifiedKeys: Set<String> = []

    /// Tracks keys that have been changed but not yet applied.
    @Published var pendingChanges: Set<String> = []

    var filteredItems: [ConfigMetadataItem] {
        if searchText.isEmpty {
            return items
        }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Returns true if there are unsaved changes.
    var hasUnsavedChanges: Bool {
        !pendingChanges.isEmpty
    }

    private let store = SettingsStore.shared

    /// True while we are applying changes, so we can ignore the
    /// resulting config-did-change notification.
    private var isApplyingChanges = false

    init() {
        loadMetadata()

        // Listen for external config reloads (menu bar, SIGUSR2, etc.)
        // so we can refresh the displayed values.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onConfigDidChange(_ notification: Notification) {
        // Only care about app-wide config changes
        guard notification.object == nil else { return }
        // Don't reload if we triggered this change ourselves
        guard !isApplyingChanges else { return }
        // Don't reload if we have pending changes - user might lose work
        guard pendingChanges.isEmpty else { return }
        loadCurrentValues()
    }

    // MARK: - Loading

    func loadMetadata() {
        let count = ghostty_config_metadata_count()
        var loadedItems: [ConfigMetadataItem] = []

        for i in 0..<count {
            guard let entry = ghostty_config_metadata_get(i) else { continue }

            let name = String(cString: entry.pointee.name)
            let fieldType = ConfigFieldType(rawValue: Int(entry.pointee.field_type.rawValue)) ?? .string

            // Load options for enum types
            var options: [String] = []
            if fieldType == .option && entry.pointee.options_count > 0 {
                for j in 0..<entry.pointee.options_count {
                    if let optionPtr = entry.pointee.options[j] {
                        options.append(String(cString: optionPtr))
                    }
                }
            }

            loadedItems.append(ConfigMetadataItem(
                id: Int(i),
                name: name,
                fieldType: fieldType,
                options: options
            ))
        }

        self.items = loadedItems
        loadCurrentValues()
    }

    /// Reads the current value of every config key from the live config.
    func loadCurrentValues() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        guard let config = delegate.ghostty.config.config else { return }

        var loaded: [String: String] = [:]
        var modified: Set<String> = []

        for item in items {
            // Read the effective value from the live config
            loaded[item.name] = SettingsStore.readValue(from: config, key: item.name)

            // Track which keys have a GUI override
            if store.isSet(item.name) {
                modified.insert(item.name)
            }
        }

        self.values = loaded
        self.modifiedKeys = modified
    }

    // MARK: - Bindings

    func binding(for name: String) -> Binding<String> {
        Binding(
            get: { self.values[name] ?? "" },
            set: { [weak self] newValue in
                guard let self else { return }
                // Only mark as pending if the value actually changed
                let oldValue = self.values[name] ?? ""
                guard newValue != oldValue else { return }
                self.values[name] = newValue
                self.pendingChanges.insert(name)
            }
        )
    }

    func boolBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { self.values[name] == "true" },
            set: { [weak self] newValue in
                guard let self else { return }
                let strValue = newValue ? "true" : "false"
                // Only mark as pending if the value actually changed
                let oldValue = self.values[name] ?? ""
                guard strValue != oldValue else { return }
                self.values[name] = strValue
                self.pendingChanges.insert(name)
            }
        )
    }

    // MARK: - Apply & Reset

    /// Saves all pending changes to the store and triggers a config reload.
    func applyChanges() {
        for key in pendingChanges {
            if let value = values[key] {
                store.save(key, value: value)
                modifiedKeys.insert(key)
            }
        }
        pendingChanges.removeAll()

        isApplyingChanges = true
        reloadConfig()
        isApplyingChanges = false
    }

    /// Discards all pending changes and reverts to the current config values.
    func discardChanges() {
        pendingChanges.removeAll()
        loadCurrentValues()
    }

    /// Removes a GUI override for a key, restoring the file/default value.
    func resetKey(_ key: String) {
        store.remove(key)
        modifiedKeys.remove(key)
        pendingChanges.remove(key)

        isApplyingChanges = true
        reloadConfig()
        isApplyingChanges = false

        // After reload, re-read this key's effective value from the live config
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        guard let config = delegate.ghostty.config.config else { return }
        values[key] = SettingsStore.readValue(from: config, key: key)
    }

    /// Triggers a full config reload through the app and captures any errors.
    private func reloadConfig() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.ghostty.reloadConfig()

        // After reload, read back errors from the new config
        let configErrors = delegate.ghostty.config.errors
        DispatchQueue.main.async {
            self.errors = configErrors
        }
    }
}

// MARK: - Views

/// Main GUI Settings view
struct GUISettingsView: View {
    @StateObject private var viewModel = ConfigMetadataViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Inline error banner
            if !viewModel.errors.isEmpty {
                ConfigErrorBanner(errors: viewModel.errors)
            }

            // Header with Apply/Discard buttons
            HStack {
                Text("Configuration Options")
                    .font(.headline)
                Spacer()

                if viewModel.hasUnsavedChanges {
                    Text("\(viewModel.pendingChanges.count) unsaved")
                        .font(.caption)
                        .foregroundColor(.orange)

                    Button("Discard") {
                        viewModel.discardChanges()
                    }
                    .buttonStyle(.bordered)

                    Button("Apply") {
                        viewModel.applyChanges()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("\(viewModel.filteredItems.count) of \(viewModel.items.count) options")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search options...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Config list
            List(viewModel.filteredItems) { item in
                ConfigItemRow(item: item, viewModel: viewModel)
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

/// Inline error banner displayed at the top of the settings view when
/// the most recent config reload produced diagnostics.
struct ConfigErrorBanner: View {
    let errors: [String]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("^[\(errors.count) configuration error(s)](inflect: true)")
                    .fontWeight(.medium)
                Spacer()
                Button(action: { withAnimation { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(errors, id: \.self) { error in
                            Text(error)
                                .font(.system(size: 11).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 120)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.1))
    }
}

/// Row view for a single config item
struct ConfigItemRow: View {
    let item: ConfigMetadataItem
    @ObservedObject var viewModel: ConfigMetadataViewModel

    private var isModified: Bool {
        viewModel.modifiedKeys.contains(item.name)
    }

    private var isPending: Bool {
        viewModel.pendingChanges.contains(item.name)
    }

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text(item.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(isModified ? .accentColor : .primary)

                // Show indicator for pending changes
                if isPending {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Unsaved change")
                }
            }
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            // Reset button, visible only for GUI-overridden keys
            if isModified {
                Button(action: { viewModel.resetKey(item.name) }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }

            // Render appropriate control based on field type
            switch item.fieldType {
            case .boolean:
                Toggle("", isOn: viewModel.boolBinding(for: item.name))
                    .toggleStyle(.switch)
                    .labelsHidden()

            case .option:
                Picker("", selection: viewModel.binding(for: item.name)) {
                    ForEach(item.options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)

            case .string:
                TextField("", text: viewModel.binding(for: item.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
        .padding(.vertical, 4)
    }
}

struct GUISettingsView_Previews: PreviewProvider {
    static var previews: some View {
        GUISettingsView()
    }
}
