import SwiftUI
import MacBenchCore

/// Where you are, and a way back up. Clickable, because a breadcrumb that is only
/// decoration wastes the row it sits in.
struct PathBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            if model.breadcrumb.isEmpty {
                Text(title).font(.title3.weight(.semibold))
            } else {
                ForEach(model.breadcrumb) { crumb in
                    if crumb.id > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    CrumbButton(crumb: crumb,
                                isLast: crumb.id == model.breadcrumb.count - 1)
                }
            }
            Spacer(minLength: 8)
        }
    }

    private var title: LocalizedStringKey {
        switch model.selection {
        case .activity: "Latest activity"
        case .openTasks: "Tasks"
        default: ""
        }
    }
}

/// One step of the path, as something you can go back to. The row was a label
/// for long enough that the way back up was the sidebar or nothing — which is a
/// long way round for "the folder this is in".
private struct CrumbButton: View {
    @Environment(AppModel.self) private var model
    let crumb: Crumb
    let isLast: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            guard let target = crumb.target else { return }
            // Clicking the folder you are already in is the way back out of one
            // of its files: the list stays, the stream stops being about one row
            // of it.
            if model.selection == target {
                model.selectedFile = nil
            } else {
                model.selection = target
            }
        } label: {
            Text(crumb.name)
                .font(isLast ? .title3.weight(.semibold) : .title3)
                .foregroundStyle(isLast ? .primary : .secondary)
                .underline(isHovering && leadsSomewhere)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(!leadsSomewhere)
        .onHover { isHovering = $0 }
        // The whole name, for the ones a narrow column cuts short.
        .help(crumb.name)
    }

    /// The part you are standing on is not a destination. Neither is the file at
    /// the end of the path — unless a file is picked, in which case the folder
    /// holding it is the way back out.
    private var leadsSomewhere: Bool {
        guard let target = crumb.target else { return false }
        return target != model.selection || model.selectedFile != nil
    }
}

/// Small and quiet when everything is fine. The point is that "waiting for sync"
/// never looks like "nothing happened".
struct SyncIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let projectID = model.currentProjectID, let status = model.engineStatus[projectID] {
            switch status.phase {
            case .buildingIndex(let found):
                Label("Indexing \(found) items…", systemImage: "circle.dotted")
                    .font(.caption).foregroundStyle(.secondary)
            case .catchingUp:
                Label("Checking what changed…", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            case .live where status.deferredIncoming > 0:
                Label("\(status.deferredIncoming) waiting to be attributed",
                      systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Changes that arrived through sync. The other Mac is being given a moment to say who made them.")
            case .live where !status.pending.isEmpty:
                Label("\(status.pending.count) being gathered", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Changes seen just now. Quiet ones are gathered for twenty minutes so that a whole afternoon of saving becomes one line.")
            default:
                EmptyView()
            }
        }
    }
}

/// What the stream shows.
///
/// A checkbox, where there used to be a menu of four: everything, without file
/// changes, open tasks, done. The two task entries were the Tasks list a second
/// time, one level down and harder to find, and the one question left over is a
/// yes or a no.
struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            // Named after what it takes away, because "messages only" was read as
            // "without tasks" — and a task is a message with a box next to it.
            Toggle("Without file changes", isOn: Binding(
                get: { !model.filter.includeSystem },
                set: { model.filter.includeSystem = !$0 }))
                .toggleStyle(.checkbox)
                .controlSize(.small)

            // Own row: the chips need the width, and squeezing them beside another
            // control in a 320-point column left neither of them legible.
            if !model.categories.isEmpty {
                CategoryChips(selection: $model.filter.categories)
            }
        }
        .font(.callout)
    }
}

/// One project out of the two lists that span all of them. Picking one is one
/// click, and the same click on the same pill is the way back to all of them —
/// a single choice, not a set, because "these two of my three projects" is not
/// a question anybody has asked.
///
/// Not there with one project: a pill that can only ever narrow the list to
/// itself is a control that does nothing.
struct ProjectChips: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    var body: some View {
        if model.projects.count > 1 {
            FlowLayout(spacing: 5) {
                ForEach(model.projects) { project in
                    ProjectChip(name: project.name, isOn: selection == project.id) {
                        selection = selection == project.id ? nil : project.id
                    }
                }
            }
            .font(.callout)
        }
    }
}

private struct ProjectChip: View {
    let name: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(name, systemImage: "folder.badge.person.crop")
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? Color.accentColor : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isOn ? Color.accentColor.opacity(0.16) : Color.clear, in: .capsule)
        .overlay(Capsule().stroke(.separator, lineWidth: isOn ? 0 : 1))
        .contentShape(.capsule)
        .help(isOn ? "Show every project again" : "Show only this project")
    }
}

/// The order of the file list.
///
/// One control rather than a column to sort by plus a direction to sort it in:
/// "newest first" is a single decision, and asking for it in two menus is two
/// things to get right before the list says anything.
enum FileSort: String, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    init(stored: String?) {
        self = FileSort(rawValue: stored ?? "") ?? .nameAscending
    }

    var title: LocalizedStringKey {
        switch self {
        case .nameAscending: "Name A–Z"
        case .nameDescending: "Name Z–A"
        case .newestFirst: "Changed, newest first"
        case .oldestFirst: "Changed, oldest first"
        }
    }

    var symbolName: String {
        switch self {
        case .nameAscending, .nameDescending: "textformat"
        case .newestFirst, .oldestFirst: "clock"
        }
    }

    var isByDate: Bool { self == .newestFirst || self == .oldestFirst }

    func sorted(_ items: [FileListItem]) -> [FileListItem] {
        items.sorted { comesFirst($0.node, $1.node) }
    }

    func sorted(_ folders: [Node]) -> [Node] {
        folders.sorted { comesFirst($0, $1) }
    }

    /// A node the index holds no modification date for goes last in both
    /// directions rather than to the top of one of them: a row that jumps once
    /// the date arrives is worse than a row at the end.
    private func comesFirst(_ a: Node, _ b: Node) -> Bool {
        switch self {
        case .nameAscending: byName(a, b)
        case .nameDescending: byName(b, a)
        case .newestFirst, .oldestFirst:
            switch (a.contentModifiedAt, b.contentModifiedAt) {
            case (nil, _?): false
            case (_?, nil): true
            case (let left?, let right?) where left != right:
                self == .newestFirst ? left > right : left < right
            default: byName(a, b)
            }
        }
    }

    private func byName(_ a: Node, _ b: Node) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Sits with the line that counts the list rather than in the toolbar: it
/// describes this list, and it is meaningless in the two that span projects.
struct SortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("", selection: $model.fileSort) {
                ForEach(FileSort.allCases) { order in
                    Label(order.title, systemImage: order.symbolName).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.fileSort.title, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .font(.caption)
        .help("The order of this list")
    }
}

struct AssigneeMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: AssigneeFilter

    var body: some View {
        Menu {
            // Just "everyone" or one person. A third option for tasks nobody has
            // been given reads as a near-synonym of the first and made the menu a
            // puzzle rather than a filter.
            Button("Anyone") { selection = .anyone }
            Divider()
            ForEach(model.members) { member in
                Button(member.id == model.identity?.member.id
                       ? String(localized: "Me") : member.name) {
                    selection = .member(member.id)
                }
            }
        } label: {
            Label(label, systemImage: "person")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("Show only the tasks meant for one person")
    }

    private var label: String {
        switch selection {
        case .anyone, .unassigned: String(localized: "Anyone")
        case .member(let id):
            id == model.identity?.member.id
                ? String(localized: "Me")
                : (model.members.first { $0.id == id }?.name ?? String(localized: "Anyone"))
        }
    }
}

struct CategoryChips: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<UUID>

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(model.categories) { category in
                CategoryChip(category: category,
                             isOn: selection.contains(category.id)) {
                    if selection.contains(category.id) {
                        selection.remove(category.id)
                    } else {
                        selection.insert(category.id)
                    }
                }
            }
        }
    }
}

/// Lays items out in a row and wraps to the next when the width runs out.
/// SwiftUI has no such layout, and an HStack in a narrow inspector squeezes every
/// chip until none of them can be read.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += row.indices.isEmpty ? size.width : size.width + spacing
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct CategoryChip: View {
    let category: MacBenchCore.Category
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Circle().fill(Color(hex: category.colorHex)).frame(width: 7, height: 7)
                Text(Format.categoryName(category))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isOn ? Color(hex: category.colorHex).opacity(0.18) : Color.clear,
                    in: .capsule)
        .overlay(Capsule().stroke(.separator, lineWidth: isOn ? 0 : 1))
        .contentShape(.capsule)
    }
}
