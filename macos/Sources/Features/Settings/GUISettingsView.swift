import Combine
import GhosttyKit
import SwiftUI

enum ConfigFieldType: Int {
    case string = 0
    case boolean = 1
    case option = 2
}

struct ConfigMetadataItem: Identifiable, Equatable {
    let id: Int
    let name: String
    let fieldType: ConfigFieldType
    let description: String
    let category: String
    let options: [String]
}

class ConfigMetadataViewModel: ObservableObject {
    @Published var items: [ConfigMetadataItem] = []
    @Published var searchText: String = ""
    @Published var values: [String: String] = [:]
    @Published var errors: [String] = []
    @Published var selectedCategory: String? = nil

    @Published var modifiedKeys: Set<String> = []
    @Published var pendingChanges: Set<String> = []

    @Published private(set) var categories: [String] = []
    @Published private(set) var itemsByCategory: [String: [ConfigMetadataItem]] = [:]

    /// Cached search results grouped by category, rebuilt on debounced search text changes.
    @Published private(set) var searchResultsByCategory:
        [(category: String, items: [ConfigMetadataItem])] = []

    private var searchCancellable: AnyCancellable?

    func items(for category: String) -> [ConfigMetadataItem] {
        itemsByCategory[category] ?? []
    }

    var hasUnsavedChanges: Bool { !pendingChanges.isEmpty }

    private func rebuildCategoryIndex() {
        let grouped = Dictionary(grouping: items) {
            $0.category.isEmpty ? "General" : $0.category
        }
        self.itemsByCategory = grouped

        let present = Set(grouped.keys)

        // These are some categories we expect are present,
        // so just ranking in a more ergonomic order
        let knownOrder = [
            "General", "Font", "Colors", "Cursor", "Mouse", "Keyboard",
            "Clipboard", "Window", "Split", "Tab", "Terminal", "Shell",
            "Appearance", "Desktop", "OS", "Linux",
        ]
        var result = knownOrder.filter { present.contains($0) }
        let extras = present.subtracting(knownOrder).sorted()
        result.append(contentsOf: extras)
        self.categories = result
    }

    private func rebuildSearchResults() {
        guard !searchText.isEmpty else {
            searchResultsByCategory = []
            return
        }
        let query = searchText
        let filtered = items.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
        let grouped = Dictionary(grouping: filtered) {
            $0.category.isEmpty ? "General" : $0.category
        }
        searchResultsByCategory =
            categories
            .filter { grouped[$0] != nil }
            .map { (category: $0, items: grouped[$0]!) }
    }

    // Flag to override how configuration errors are propagated to the user.
    // Instead of showing a popup window, we show errors inline in the preferences panel.
    static var isReloadingFromGUI = false

    private let store = SettingsStore.shared
    private var isApplyingChanges = false

    init() {
        loadMetadata()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onConfigDidChange(_:)),
            name: .ghosttyConfigDidChange, object: nil)
        searchCancellable =
            $searchText
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildSearchResults() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func onConfigDidChange(_ notification: Notification) {
        guard notification.object == nil else { return }
        guard !isApplyingChanges else { return }
        guard pendingChanges.isEmpty else { return }
        loadCurrentValues()
    }

    // MARK: - Initial loading of data

    func loadMetadata() {
        let count = ghostty_config_metadata_count()
        var loadedItems: [ConfigMetadataItem] = []

        for i in 0..<count {
            guard let entry = ghostty_config_metadata_get(i) else { continue }
            let name = String(cString: entry.pointee.name)
            let fieldType =
                ConfigFieldType(rawValue: Int(entry.pointee.field_type.rawValue)) ?? .string
            let description = entry.pointee.description.map(String.init(cString:)) ?? ""
            let category = entry.pointee.category.map(String.init(cString:)) ?? ""

            var options: [String] = []
            if fieldType == .option && entry.pointee.options_count > 0 {
                for j in 0..<entry.pointee.options_count {
                    if let ptr = entry.pointee.options[j] {
                        options.append(String(cString: ptr))
                    }
                }
            }

            loadedItems.append(
                ConfigMetadataItem(
                    id: Int(i), name: name, fieldType: fieldType,
                    description: description, category: category, options: options
                ))
        }

        self.items = loadedItems
        rebuildCategoryIndex()
        loadCurrentValues()
        if selectedCategory == nil, let first = categories.first {
            selectedCategory = first
        }
    }

    func loadCurrentValues() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        guard let config = delegate.ghostty.config.config else { return }

        var loaded: [String: String] = [:]
        var modified: Set<String> = []
        for item in items {
            loaded[item.name] = SettingsStore.readValue(from: config, key: item.name)
            if store.isSet(item.name) { modified.insert(item.name) }
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
                guard newValue != (self.values[name] ?? "") else { return }
                self.values[name] = newValue
                self.pendingChanges.insert(name)
            }
        )
    }

    // MARK: - Apply & Reset

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

    func discardChanges() {
        pendingChanges.removeAll()
        loadCurrentValues()
    }

    func resetKey(_ key: String) {
        store.remove(key)
        modifiedKeys.remove(key)
        pendingChanges.remove(key)
        isApplyingChanges = true
        reloadConfig()
        isApplyingChanges = false
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        guard let config = delegate.ghostty.config.config else { return }
        values[key] = SettingsStore.readValue(from: config, key: key)
    }

    private func reloadConfig() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        Self.isReloadingFromGUI = true
        delegate.ghostty.reloadConfig()
        Self.isReloadingFromGUI = false
        let configErrors = delegate.ghostty.config.errors
        DispatchQueue.main.async { self.errors = configErrors }
    }
}

// MARK: - Category Metadata

private struct CategoryInfo {
    let icon: String
    let color: Color
}

private let categoryMeta: [String: CategoryInfo] = [
    "General": CategoryInfo(icon: "gearshape", color: Color(.systemGray)),
    "Font": CategoryInfo(icon: "textformat.size", color: .blue),
    "Colors": CategoryInfo(icon: "paintpalette.fill", color: .pink),
    "Cursor": CategoryInfo(icon: "cursorarrow", color: .purple),
    "Mouse": CategoryInfo(icon: "computermouse.fill", color: .orange),
    "Keyboard": CategoryInfo(icon: "keyboard", color: .indigo),
    "Clipboard": CategoryInfo(icon: "doc.on.clipboard", color: .green),
    "Window": CategoryInfo(icon: "macwindow", color: .teal),
    "Split": CategoryInfo(icon: "rectangle.split.2x1", color: .brown),
    "Tab": CategoryInfo(icon: "square.on.square", color: .mint),
    "Terminal": CategoryInfo(icon: "terminal", color: .gray),
    "Shell": CategoryInfo(icon: "chevron.left.forwardslash.chevron.right", color: .red),
    "Appearance": CategoryInfo(icon: "sparkles", color: .cyan),
    "Desktop": CategoryInfo(icon: "menubar.dock.rectangle", color: .yellow),
    "OS": CategoryInfo(icon: "desktopcomputer", color: .brown),
    "Linux": CategoryInfo(icon: "server.rack", color: .mint),
]

// MARK: - Main View

struct GUISettingsView: View {
    @StateObject private var viewModel = ConfigMetadataViewModel()

    var body: some View {
        HSplitView {
            SidebarView(viewModel: viewModel)
                .frame(minWidth: 180, idealWidth: 180, maxWidth: 280)

            VStack(spacing: 0) {
                DetailHeaderBar(viewModel: viewModel)
                Divider()

                if !viewModel.errors.isEmpty {
                    ConfigErrorBanner(errors: viewModel.errors)
                }

                DetailContentView(viewModel: viewModel)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var viewModel: ConfigMetadataViewModel

    var body: some View {
        List(selection: $viewModel.selectedCategory) {
            ForEach(viewModel.categories, id: \.self) { category in
                let meta = categoryMeta[category] ?? CategoryInfo(icon: "gearshape", color: .gray)
                let count = viewModel.itemsByCategory[category]?.count ?? 0

                Label {
                    HStack {
                        Text(category)
                        Spacer()
                        Text("\(count)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: meta.icon)
                        .foregroundStyle(meta.color)
                        .frame(width: 20)
                }
                .tag(category)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Detail Header Bar

struct DetailHeaderBar: View {
    @ObservedObject var viewModel: ConfigMetadataViewModel

    private var title: String {
        if !viewModel.searchText.isEmpty {
            return "Search Results"
        }
        return viewModel.selectedCategory ?? "Settings"
    }

    private var subtitle: String {
        if !viewModel.searchText.isEmpty {
            let count = viewModel.searchResultsByCategory.reduce(0) { $0 + $1.items.count }
            return "\(count) match\(count == 1 ? "" : "es")"
        }
        if let cat = viewModel.selectedCategory {
            let count = viewModel.itemsByCategory[cat]?.count ?? 0
            return "\(count) option\(count == 1 ? "" : "s")"
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if viewModel.hasUnsavedChanges {
                Text("\(viewModel.pendingChanges.count) unsaved")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Button("Discard") {
                    viewModel.discardChanges()
                }
                .controlSize(.small)

                Button("Apply") {
                    viewModel.applyChanges()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }

            SearchField(text: $viewModel.searchText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Search Field

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .frame(width: 180)
    }
}

// MARK: - Detail Content

struct DetailContentView: View {
    @ObservedObject var viewModel: ConfigMetadataViewModel

    var body: some View {
        if !viewModel.searchText.isEmpty {
            searchResults
        } else if let category = viewModel.selectedCategory {
            categoryList(category)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let groups = viewModel.searchResultsByCategory
        if groups.isEmpty {
            noResults
        } else {
            List {
                ForEach(groups, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.items) { item in
                            ConfigItemRow(
                                item: item,
                                value: viewModel.binding(for: item.name),
                                isModified: viewModel.modifiedKeys.contains(item.name),
                                isPending: viewModel.pendingChanges.contains(item.name),
                                onReset: { viewModel.resetKey(item.name) }
                            )
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        }
    }

    private func categoryList(_ category: String) -> some View {
        List {
            Section {
                ForEach(viewModel.items(for: category)) { item in
                    ConfigItemRow(
                        item: item,
                        value: viewModel.binding(for: item.name),
                        isModified: viewModel.modifiedKeys.contains(item.name),
                        isPending: viewModel.pendingChanges.contains(item.name),
                        onReset: { viewModel.resetKey(item.name) }
                    )
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .id(category)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("Select a category")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("No results for \"\(viewModel.searchText)\"")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Config Item Row

struct ConfigItemRow: View {
    let item: ConfigMetadataItem
    @Binding var value: String
    let isModified: Bool
    let isPending: Bool
    let onReset: () -> Void

    @State private var isHovering = false
    @State private var showFullDescription = false

    private var boolValue: Binding<Bool> {
        Binding(
            get: { value == "true" },
            set: { value = $0 ? "true" : "false" }
        )
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(isModified ? Color.accentColor : .primary)

                    if isPending {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .help("Unsaved change")
                    }
                }

                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .onTapGesture {
                            showFullDescription.toggle()
                        }
                        .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                            ScrollView {
                                Text(item.description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(12)
                                    .frame(maxWidth: 400, alignment: .leading)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: 420, maxHeight: 300)
                        }
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
                .opacity(isModified && isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)

                controlView
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    @ViewBuilder
    private var controlView: some View {
        switch item.fieldType {
        case .boolean:
            Toggle("", isOn: boolValue)
                .toggleStyle(.switch)
                .labelsHidden()

        case .option:
            Picker("", selection: $value) {
                ForEach(item.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)

        case .string:
            TextField("", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }
}

// MARK: - Error Banner

struct ConfigErrorBanner: View {
    let errors: [String]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)

                Text("^[\(errors.count) configuration error](inflect: true)")
                    .font(.callout.weight(.medium))

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(errors, id: \.self) { error in
                            Text(error)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 100)
                .background(.background.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.08))
    }
}

// MARK: - Preview

struct GUISettingsView_Previews: PreviewProvider {
    static var previews: some View {
        GUISettingsView()
    }
}
