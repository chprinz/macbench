import SwiftUI
import MacBenchCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section {
                    SmartRow(selection: .activity, title: "Latest activity", symbol: "clock",
                             count: model.signals.unreadTotal, tint: .accentColor,
                             help: "Everything that has happened in every project, oldest first. The number counts what you have not read yet; the list opens where you stopped.")
                    SmartRow(selection: .openTasks, title: "Tasks", symbol: "checklist",
                             count: model.signals.openTaskTotal, tint: .secondary,
                             help: "Every task nobody has ticked off yet, from every project.")
                }

                Section {
                    ForEach(model.visibleTree) { item in
                        TreeRow(item: item)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Projects")
                            Spacer()
                            Button {
                                if let url = FolderPicker.chooseProjectFolder() {
                                    Task { await model.addProject(url: url) }
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .help("Add a project folder")
                        }
                        // Sits above the tree and narrows what is shown. It never
                        // rearranges anything: the structure people have learned
                        // stays where they learned it.
                        Picker("", selection: $model.sidebarFilter) {
                            ForEach(AppModel.SidebarFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .labelsHidden()
                        .padding(.trailing, 6)
                        .padding(.bottom, 2)
                    }
                }
            }
            .listStyle(.sidebar)
            if !model.catchingUp.allSatisfy(\.isStuck) || !model.arrived.isEmpty {
                SyncFooter()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.catchingUp)
        .animation(.default, value: model.arrived)
        // Deliberately here and not on the row: a context menu tears its host down
        // as it closes, and a dialog owned by that host goes with it — the menu
        // item then does nothing at all.
        .confirmationDialog("Stop watching “\(removalName)”?",
                            isPresented: Binding(get: { model.projectPendingRemoval != nil },
                                                 set: { if !$0 { model.projectPendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Project", role: .destructive) {
                if let id = model.projectPendingRemoval {
                    model.projectPendingRemoval = nil
                    Task { await model.removeProject(id) }
                }
            }
            Button("Cancel", role: .cancel) { model.projectPendingRemoval = nil }
        } message: {
            Text("Your files stay where they are, and so does the history stored beside them in .macbench. Adding the folder again reads it back.")
        }
    }

    private var removalName: String {
        model.projects.first { $0.id == model.projectPendingRemoval }?.name ?? ""
    }

}

private struct SmartRow: View {
    @Environment(AppModel.self) private var model
    let selection: Selection
    let title: LocalizedStringKey
    let symbol: String
    let count: Int
    let tint: Color
    let help: LocalizedStringKey

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(count > 0 ? tint : .secondary)
        }
        .tag(selection)
        .help(help)
    }
}

private struct TreeRow: View {
    @Environment(AppModel.self) private var model
    let item: TreeItem

    var body: some View {
        if let children = item.children, !children.isEmpty {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(children) { child in TreeRow(item: child) }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { model.expanded.contains(item.id) },
            set: { isOpen in
                if isOpen { model.expanded.insert(item.id) } else { model.expanded.remove(item.id) }
            })
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: item.isProject ? "folder.badge.person.crop" : "folder")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if item.isProject { PeerLoadingIndicator(catchingUp: model.catchingUp(project: item.projectID)) }
            if model.hasOpenTasks(item) {
                Image(systemName: "checkmark.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            if model.hasUnread(item) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            }
        }
        .tag(item.id)
        .contextMenu { TreeContextMenu(item: item) }
    }
}

/// Where something is on its way. Only the project is known: until the log file
/// is here, nobody can say which file or folder the changes inside it are about.
private struct PeerLoadingIndicator: View {
    let catchingUp: [AppModel.PeerCatchUp]

    var body: some View {
        let names = Set(catchingUp.map(\.who)).sorted().formatted(.list(type: .and))
        if catchingUp.contains(where: \.isStuck) {
            Image(systemName: "exclamationmark.icloud")
                .imageScale(.small)
                .foregroundStyle(.orange)
                .help("iCloud has not delivered the changes from \(names) for over ten minutes.")
        } else if !catchingUp.isEmpty {
            ProgressView()
                .controlSize(.mini)
                .help("Loading changes from \(names)")
        }
    }
}

/// What is on its way from the other machines, at the foot of the sidebar. Not a
/// banner: iCloud taking a few seconds is not a problem, and a warning for it
/// teaches people to ignore the warnings that are.
private struct SyncFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let loading = model.catchingUp.filter { !$0.isStuck }
        Group {
            if !loading.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Loading changes from \(list(loading.map(\.who)))")
                        Text(list(loading.map { projectName($0.projectID) }))
                            .foregroundStyle(.tertiary)
                    }
                }
                .help("iCloud has announced these changes but not downloaded them yet. That usually takes a few seconds, and there is nothing to do.")
            } else if !model.arrived.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("Everything from \(list(model.arrived)) has arrived")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func projectName(_ id: UUID) -> String {
        model.projects.first { $0.id == id }?.name ?? ""
    }

    /// Each name once, in the order they started waiting.
    private func list(_ names: [String]) -> String {
        var seen: [String] = []
        for name in names where !seen.contains(name) { seen.append(name) }
        return seen.formatted(.list(type: .and))
    }
}

private struct TreeContextMenu: View {
    @Environment(AppModel.self) private var model
    let item: TreeItem

    var body: some View {
        if !item.isProject {
            Button("Show in Finder") { model.revealFolder(item) }
            Button("Mark as Read") { model.markAllRead(project: item.projectID) }
            Divider()
            Button("Stop Watching This Folder") {
                Task { await model.exclude(path: item.path, in: item.projectID) }
            }
        }
        if item.isProject {
            Menu("Change Stream") {
                ForEach(Verbosity.allCases, id: \.self) { level in
                    Button {
                        model.setVerbosity(level, for: item.projectID)
                    } label: {
                        HStack {
                            Text(title(for: level))
                            if model.verbosity(for: item.projectID) == level {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Button("Mark Project as Read") { model.markAllRead(project: item.projectID) }
            Button("Check Folder Now") { Task { await model.rescan(item.projectID) } }
            Divider()
            Button("Remove Project…", role: .destructive) { model.projectPendingRemoval = item.projectID }
        }
    }

    private func title(for level: Verbosity) -> LocalizedStringKey {
        switch level {
        case .everything: "Everything"
        case .majorOnly: "Only bigger events"
        case .off: "Off — only what we write"
        }
    }
}
