import SwiftUI
import MacBenchCore

/// The middle column when the sidebar points at Tasks.
///
/// Every other selection answers "which files". This one answers "what still has
/// to be done, and by whom" — a different question, and the only one in the app
/// where a list of files is the wrong answer: it made you open every file to find
/// out which task was yours. The list is grouped by the person a task is for,
/// yours first, so that question is answered before it is asked.
struct TaskListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                PathBar()
                // Wrapping, not fixed: a fixed-size switch and a menu side by side
                // were a minimum width for the whole column, and the column simply
                // clipped when the window could not give it.
                FlowLayout(spacing: 8) {
                    Picker("", selection: $model.taskFilter.status) {
                        // Not "Open": that key is the button that opens a file,
                        // and it is "Öffnen" in German — a verb where this wants
                        // an adjective.
                        Text("Still open").tag(StatusFilter.openTasks)
                        Text("Done").tag(StatusFilter.doneTasks)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    AssigneeMenu(selection: $model.taskFilter.assignee)
                }
                .controlSize(.small)

                ProjectChips(selection: $model.taskFilter.project)

                if !model.categories.isEmpty {
                    CategoryChips(selection: $model.taskFilter.categories)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.tasks.isEmpty {
            EmptyStateView(title: isDone ? "Nothing ticked off yet" : "No open tasks",
                           hint: isDone
                           ? "Tasks that somebody has ticked off collect here, newest first. Ticking one open again puts it back under open tasks."
                           : "A message becomes a task by ticking the box next to the text field before sending it. Open tasks from every project collect here until somebody ticks them off.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                TaskRow(item: item)
                                Divider().padding(.leading, 38)
                            }
                        } header: {
                            GroupHeader(title: group.title, count: group.items.count)
                        }
                    }
                }
            }
        }
    }

    private var isDone: Bool { model.taskFilter.status == .doneTasks }

    private struct Group: Identifiable {
        var id: String
        var title: String
        var items: [TimelineItem]
    }

    /// Whose work it is, and mine at the top. Inside a group the oldest open task
    /// comes first — it is the one that has been waiting longest — while ticked
    /// ones read newest first, because that list is a record of what just got
    /// done.
    private var groups: [Group] {
        var byPerson: [UUID?: [TimelineItem]] = [:]
        for item in model.tasks {
            byPerson[item.entry.assigneeID, default: []].append(item)
        }
        let sort: ([TimelineItem]) -> [TimelineItem] = { items in
            isDone ? items.sorted { $0.entry.createdAt > $1.entry.createdAt } : items
        }

        var result: [Group] = []
        let me = model.identity?.member.id
        if let me, let mine = byPerson[me] {
            result.append(Group(id: me.uuidString, title: String(localized: "For you"),
                                items: sort(mine)))
        }
        for member in model.members where member.id != me {
            guard let items = byPerson[member.id] else { continue }
            result.append(Group(id: member.id.uuidString,
                                title: String(localized: "For \(member.name)"),
                                items: sort(items)))
        }
        // For a person whose Mac has not written into any folder this one reads:
        // somebody in a third project assigned it. These fell through every group
        // and were missing from the list while the sidebar still counted them.
        let known = Set(model.members.map(\.id))
        let unknown = model.tasks.filter { $0.entry.assigneeID.map { !known.contains($0) && $0 != me } ?? false }
        if !unknown.isEmpty {
            result.append(Group(id: "unknown", title: String(localized: "For someone this Mac does not know yet"),
                                items: sort(unknown)))
        }
        if let nobody = byPerson[nil] {
            result.append(Group(id: "unassigned",
                                title: String(localized: "Not for anybody in particular"),
                                items: sort(nobody)))
        }
        return result
    }
}

private struct GroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.background)
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let item: TimelineItem
    @State private var isHovering = false
    @State private var draft: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TaskCheckbox(isDone: item.entry.isDone) { done in
                Task { await model.setTask(item.entry, done: done) }
            }

            VStack(alignment: .leading, spacing: 3) {
                if draft != nil {
                    // Deliberately not Binding($draft): that projection force-
                    // unwraps, and committing the edit sets draft to nil while
                    // SwiftUI is still reading through it — which is a crash, not
                    // a redraw. This one reads the optional and survives it.
                    let editing = Binding(get: { draft ?? "" }, set: { draft = $0 })
                    TextField("", text: editing, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onKeyPress(keys: [.escape], phases: .down) { _ in
                            draft = nil
                            return .handled
                        }
                        .onReturnKey(perform: commitEdit)
                    HStack(spacing: 8) {
                        Button("Save") { commitEdit() }
                        Button("Cancel") { draft = nil }
                    }
                    .controlSize(.small)
                } else {
                    // The task, and the buttons on the same line as the task —
                    // aligned with the first line of it rather than floating at
                    // the top of whatever height the row happens to have.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.linked(item.entry.text))
                            .font(.body)
                            .strikethrough(item.entry.isDone, color: .secondary)
                            .foregroundStyle(item.entry.isDone ? .secondary : .primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        actions
                    }
                }
                details
            }
        }
        .padding(.horizontal, RowInset.text)
        .padding(.vertical, 7)
        .background(background, in: RowInset.shape)
        .padding(.horizontal, RowInset.edge)
        .contentShape(.rect)
        .animation(.easeOut(duration: 0.45), value: model.flashingEntry)
        .onHover { isHovering = $0 }
        // A double click opens the file, as it does on a file row. Showing the
        // messages is what the toolbar button and the row's menu are for.
        .onTapGesture(count: 2) {
            model.selectedEntry = item
            if let node = fileNode { model.open(node) }
        }
        .onTapGesture { model.selectedEntry = item }
        .contextMenu { EntryMenu(item: item, draft: $draft, offersStream: true) }
    }

    @ViewBuilder
    private var actions: some View {
        RowActions(node: fileNode) {
            EntryMenu(item: item, draft: $draft, offersStream: true)
        }
        .hoverReveal(isHovering || isSelected)
    }

    private var background: Color {
        if model.flashingEntry == item.id { return .accentColor.opacity(0.28) }
        return isSelected ? .accentColor.opacity(0.12) : .clear
    }

    /// Who, when and which file, then where that file lives — the same order
    /// as a line in the feed. It was one path from project to file behind the
    /// name, which put the file, the part that says what the task is about, last,
    /// and ran out of the column when the folders had long names.
    @ViewBuilder
    private var details: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            AuthorName(member: item.author)
                .fixedSize()
            Text(Format.timestamp(item.entry.createdAt))
                .foregroundStyle(.tertiary)
                .fixedSize()
            if let node = fileNode {
                FileTag(node: node)
                    .layoutPriority(-1)
            }
            ForEach(item.categories) { category in
                Text(Format.categoryName(category))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(hex: category.colorHex).opacity(0.16), in: .capsule)
                    .fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        let project = model.projectLabel(for: item.entry, narrowedTo: model.taskFilter.project)
        let whereTag = PathTag(projectID: item.entry.projectID, projectName: project,
                               node: fileNode, includesFile: false)
        if !whereTag.isEmpty {
            whereTag
                .padding(.leading, -3)
                .padding(.top, -2)
        }
    }

    private var fileNode: Node? {
        guard let node = item.node, !node.isPlaceholder else { return nil }
        return node
    }

    private var isSelected: Bool { model.selectedEntry?.id == item.id }

    private func commitEdit() {
        guard let text = draft else { return }
        draft = nil
        Task { await model.edit(item.entry, text: text) }
    }
}
