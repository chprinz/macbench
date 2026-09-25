import SwiftUI
import MacBenchCore
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ProjectSettings().tabItem { Label("Projects", systemImage: "folder") }
            CategorySettings().tabItem { Label("Categories", systemImage: "tag") }
            PeopleSettings().tabItem { Label("People", systemImage: "person.2") }
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var hotKey: GlobalHotKey.Combination?

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do { try LaunchAtLogin.set(value) }
                        catch { launchAtLogin = LaunchAtLogin.isEnabled }
                    }
                if LaunchAtLogin.requiresApproval {
                    HStack {
                        Text("macOS is waiting for your approval.")
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                    .font(.caption)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Changes are captured live only while the app runs. Anything that happens while it is closed is reconstructed on the next launch by comparing the folder, with approximate timestamps.")
                    Text("Closing the window does not stop it: it keeps watching in the background, with no Dock icon. Open it again from the Finder or Spotlight. Started at login, it starts in the background.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Move deleted files to the archive after", selection: Binding(
                    get: { model.archiveAfterDays },
                    set: { model.archiveAfterDays = $0 })) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("One year").tag(365)
                    Text("Never").tag(0)
                }
            } header: {
                Text("Archive")
            } footer: {
                Text("An archived file leaves the tree, the file lists and search. Nothing is deleted: what was written about it is kept, and this setting is yours alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Text("Notifies only for a message addressed to you: a task assigned to you, or a reply to an entry of yours. File changes never notify.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Shortcut") {
                    HotKeyRecorder(combination: $hotKey)
                }
                .onChange(of: hotKey) { _, value in
                    try? model.store.setSetting(
                        AppModel.hotKeyKey, value: GlobalHotKey.StoredCombination(combination: value))
                    model.installHotKey()
                }
            } header: {
                Text("Quick note")
            } footer: {
                Text("Opens a small window from any app, so a thought can be written down without leaving what you are doing. Pick a combination your launcher does not already use.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version") {
                    Text(Brand.version).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Link("\(Brand.name) on GitHub", destination: Brand.repository)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hotKey = (try? model.store.setting(AppModel.hotKeyKey,
                                               as: GlobalHotKey.StoredCombination.self))?.combination
                ?? .default
        }
    }
}

struct ProjectSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected: UUID?
    @State private var exportedFile: URL?
    @State private var isConfirmingRemoval = false
    // A list of folder names needs far less room than the settings beside it, and
    // whatever width you drag it to is the width you meant. Measured while you
    // drag and handed back as the ideal width next time, like the main window.
    @AppStorage("layout.projectSettingsListWidth") private var listWidth = 180.0

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(model.projects) { project in
                    Text(project.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(project.id)
                }
                if !model.archivedProjects.isEmpty {
                    Section("Archived") {
                        ForEach(model.archivedProjects) { project in
                            Text(project.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .tag(project.id)
                        }
                    }
                }
            }
            .frame(minWidth: 140, idealWidth: listWidth, maxWidth: 320)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if width > 100 { listWidth = Double(width.rounded()) }
            }

            Group {
                if let selected, let project = model.projects.first(where: { $0.id == selected }) {
                    detail(for: project)
                } else if let selected,
                          let project = model.archivedProjects.first(where: { $0.id == selected }) {
                    archivedDetail(for: project)
                } else {
                    Text("Select a project").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320)
        }
        .onAppear { selected = selected ?? model.projects.first?.id }
    }

    private func archivedDetail(for project: Project) -> some View {
        Form {
            Section {
                Label("Archived", systemImage: "archivebox")
                Text("Not watched and not in the lists. Its history is kept, here and in the folder.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Bring Back") { Task { await model.setArchived(project.id, false) } }
                Text("Anything that changed in the folder meanwhile is found by comparing it, with approximate times.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Remove project…", role: .destructive) { isConfirmingRemoval = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Stop watching “\(project.name)”?",
                            isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove Project", role: .destructive) {
                Task { await model.removeProject(project.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your files stay where they are, and so does the history stored beside them in .macbench. Adding the folder again reads it back.")
        }
    }

    private func detail(for project: Project) -> some View {
        Form {
            // Where the reason lives once the banner has been put away.
            if let reason = model.unwatchedReason(for: project.id) {
                Section {
                    Label("This project is not being watched", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(reason).font(.caption).textSelection(.enabled)
                    Text("Nothing is lost while this lasts: changes are reconstructed by comparing the folder once it can be read again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Change stream") {
                Picker("Show me", selection: Binding(
                    get: { model.verbosity(for: project.id) },
                    set: { model.setVerbosity($0, for: project.id) })) {
                    Text("Everything").tag(Verbosity.everything)
                    Text("Only bigger events").tag(Verbosity.majorOnly)
                    Text("Nothing — only what we write").tag(Verbosity.off)
                }
                Text("This setting is yours alone. Turning it down here does not turn it down for anyone else.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Folder") {
                if let path = try? model.store.projectLocation(project.id)?.path {
                    Text(path).font(.caption).textSelection(.enabled)
                }
                Button("Check the folder now") { Task { await model.rescan(project.id) } }
            }

            Section {
                let excluded = model.excludedPaths(for: project.id)
                if excluded.isEmpty {
                    Text("Nothing excluded beyond the built-in list of cache and lock files.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(excluded, id: \.self) { path in
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Watch again") {
                                Task { await model.include(path: path, in: project.id) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Excluded folders")
            }

            Section("Export") {
                Button("Export history as Markdown…") { export(project) }
                Text("All entries and all changes as one Markdown file. The history should be readable without this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Remove project…", role: .destructive) { isConfirmingRemoval = true }
                Text("Stops watching it. Your files and the history stored next to them are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Stop watching “\(project.name)”?",
                            isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove Project", role: .destructive) {
                Task { await model.removeProject(project.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your files stay where they are, and so does the history stored beside them in .macbench. Adding the folder again reads it back.")
        }
    }

    private func export(_ project: Project) {
        guard let markdown = model.exportMarkdown(project: project) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct CategorySettings: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                if model.categories.isEmpty {
                    HStack {
                        Text("None yet.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Add the usual four") {
                            Task { await model.addSuggestedCategories() }
                        }
                        .controlSize(.small)
                    }
                }
                ForEach(model.categories) { category in
                    CategoryRow(category: category)
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("One level, no sub-categories, and an entry can carry several. Categories are shared with everyone in the project. A new installation starts with none — the button offers Feedback, Technical, Admin and System if you want somewhere to begin.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("New category", text: $newName)
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let name = newName
        newName = ""
        Task { await model.add(category: name) }
    }
}

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: MacBenchCore.Category
    @State private var draft = ""
    @State private var isEditing = false

    var body: some View {
        HStack {
            Circle().fill(Color(hex: category.colorHex)).frame(width: 10, height: 10)
            if isEditing {
                TextField("", text: $draft)
                    .onSubmit { commit() }
                Button("Save") { commit() }.controlSize(.small)
                Button("Cancel") { isEditing = false }.controlSize(.small)
            } else {
                Text(Format.categoryName(category))
                Spacer()
                Button("Rename") {
                    draft = Format.categoryName(category)
                    isEditing = true
                }
                .controlSize(.small)
                Button("Remove", role: .destructive) {
                    Task { await model.delete(category: category) }
                }
                .controlSize(.small)
            }
        }
    }

    private func commit() {
        isEditing = false
        Task { await model.rename(category: category, to: draft) }
    }
}

struct PeopleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var colorHex = MemberPalette.colors[0]
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                LabeledContent("Colour") { ColorSwatchPicker(selection: $colorHex) }
                HStack {
                    Spacer()
                    Button("Save") {
                        Task { await model.updateSelf(name: name, colorHex: colorHex) }
                    }
                    .disabled(!hasChanges)
                }
            } header: {
                Text("You")
            } footer: {
                Text("A change travels in the log; the other Mac picks it up on its own. Past entries keep showing the new name, because they refer to you rather than to a copy of your name.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.members.filter { $0.id != model.identity?.member.id }) { member in
                    HStack {
                        Circle().fill(Color(hex: member.colorHex)).frame(width: 12, height: 12)
                        Text(member.name)
                    }
                }
            } header: {
                Text("Everyone else")
            } footer: {
                Text("People appear here on their own, as soon as their machine writes something into a shared folder. There is nobody to invite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !loaded, let member = model.identity?.member else { return }
            name = member.name
            colorHex = member.colorHex
            loaded = true
        }
    }

    private var hasChanges: Bool {
        guard let member = model.identity?.member else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && (trimmed != member.name || colorHex != member.colorHex)
    }
}
