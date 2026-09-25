import SwiftUI
import MacBenchCore

/// What a row offers, and where.
///
/// Four lists show rows — files, tasks, the activity feed, the conversation — and
/// every one of them had grown its own answer: labelled buttons here, icons
/// there, a file that was a link in one list and plain text in the next, a menu
/// that existed on some rows and not others. That is four things to learn for one
/// gesture. These are the pieces, in one order: open the file, show it in the
/// Finder, show what was said around it, and the menu, outermost.

/// The file a row is about, as something you can click and see that you can.
struct FileTag: View {
    @Environment(AppModel.self) private var model
    let node: Node
    /// Where the chip is laid out at its natural width — inside a sentence that
    /// wraps — the name is cut here, since the layout will not cut it.
    var shortenedTo: Int?
    @State private var isHovering = false

    var body: some View {
        Button {
            model.focus(node: node)
        } label: {
            Label(shortenedTo.map { node.name.middleShortened(to: $0) } ?? node.name,
                  systemImage: "doc")
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isHovering ? Color.accentColor : .secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(isHovering ? Color.accentColor.opacity(0.12) : .clear, in: .capsule)
        .contentShape(.capsule)
        .onHover { isHovering = $0 }
        .help(node.relativePath)
    }
}

/// Where a line in a list that spans projects is: project, folders, file — each
/// part a way there. It replaces a file chip with a project name trailing behind
/// it, which said which file and which project but not where in the project, and
/// made the eye read two things for one answer.
///
/// The project is left out where the list already says it (narrowed to one, or
/// there is only one); the file is left out when the line is not about one.
struct PathTag: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    /// Nil where the list already says which project.
    let projectName: String?
    let node: Node?
    /// Off where the file is already named on the line above, as its own chip:
    /// then this is only where it lives, and says it more quietly.
    var includesFile = true

    /// True when there is nothing to say: no project to name and the file at the
    /// top level. Worked out without `steps`, whose actions read the model and so
    /// can only be built inside `body`.
    var isEmpty: Bool {
        guard projectName == nil else { return false }
        guard let node else { return true }
        return !includesFile && (node.parentPath ?? "").isEmpty
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.quaternary)
                }
                PathStep(step: step)
            }
        }
        .font(.caption2)
        .help(fullPath)
    }

    fileprivate struct Step {
        var name: String
        var isFile: Bool
        var symbol = "doc"
        var go: () -> Void
    }

    private var steps: [Step] {
        var result: [Step] = []
        if let projectName {
            result.append(Step(name: projectName, isFile: false) { [model, projectID] in
                model.selection = .project(projectID)
            })
        }
        guard let node else { return result }
        var path = ""
        for folder in (node.parentPath ?? "").split(separator: "/").map(String.init) {
            path = path.isEmpty ? folder : path + "/" + folder
            result.append(Step(name: folder, isFile: false) { [model, projectID, path] in
                model.showFolder(projectID: projectID, relativePath: path)
            })
        }
        guard includesFile else { return result }
        result.append(Step(name: node.name, isFile: true,
                           symbol: node.isDirectory ? "folder" : "doc") { [model] in model.focus(node: node) })
        return result
    }

    private var fullPath: String {
        ([projectName].compactMap { $0 } + [node?.relativePath].compactMap { $0 })
            .joined(separator: "/")
    }
}

/// One part of a path. Folders are quieter than the file and give up their
/// length first: in a narrow column the file name is the part worth keeping.
///
/// Shortened here rather than by the layout: the rows lay these out at their
/// natural width, and a width cap there turned every folder into a two-line
/// block of the same size, whatever its name.
private struct PathStep: View {
    let step: PathTag.Step
    @State private var isHovering = false

    var body: some View {
        Button(action: step.go) {
            if step.isFile {
                Label(step.name.middleShortened(to: 44), systemImage: step.symbol)
                    .lineLimit(1)
            } else {
                // One line, cut further in the middle when the column is narrower
                // still: the path used to keep its full width and run out of the
                // column, cut off at the edge where nothing said it went on.
                Text(step.name.middleShortened(to: 30))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: step.isFile, vertical: true)
        .layoutPriority(step.isFile ? 1 : 0)
        .foregroundStyle(isHovering ? AnyShapeStyle(Color.accentColor)
                         : step.isFile ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(isHovering ? Color.accentColor.opacity(0.12) : .clear, in: .capsule)
        .contentShape(.capsule)
        .onHover { isHovering = $0 }
    }
}

extension String {
    /// The start and the end, which is where these names differ: "26-09-07
    /// Kunde A Erst…Zusammenfassung.txt" still says which one it is.
    func middleShortened(to limit: Int) -> String {
        guard count > limit else { return self }
        let head = (limit - 1) / 2
        return String(prefix(head)) + "…" + String(suffix(limit - 1 - head))
    }
}

/// The way to the conversation a row belongs to — and the way back out of it —
/// as a line on the row's menu. It used to be a speech bubble on every row,
/// which was a third icon on a row that already had enough.
/// Chosen again on the row the column is already showing, it puts the column
/// away: the thing that opened something is where the hand goes to close it.
struct StreamMenuButton: View {
    @Environment(AppModel.self) private var model
    /// True when the column beside this row is currently showing this row.
    let isShowingThis: Bool
    /// What the column will show for this row, said as the user would say it.
    var showTitle: LocalizedStringKey = "Show in Messages"
    let show: () -> Void

    var body: some View {
        Button(isShowingThis ? "Hide Messages" : showTitle) {
            if isShowingThis {
                model.isStreamVisible = false
            } else {
                show()
                model.isStreamVisible = true
            }
        }
    }
}

/// The trailing cluster. Same order everywhere, icons rather than words — two
/// labelled buttons took two thirds of a row once the conversation column was
/// open, and what got shortened was the thing the row is about.
///
/// Callers show it only on hover but always lay it out (`hoverReveal`), so the
/// row keeps its width and does not rewrap under the pointer.
struct RowActions<MenuContent: View>: View {
    @Environment(AppModel.self) private var model
    /// The file to open, if the row is about one that is still there.
    var node: Node?
    /// Off where the row already shows the file as a path you can click: two
    /// more icons for the same file were noise. Both stay on the menu.
    var showsFileActions = true
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 2) {
            if showsFileActions, let node, node.state == .present {
                Button { model.open(node) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open")
                Button { model.reveal(node) } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
            }
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.callout)
    }
}

extension View {
    /// Visible and clickable only while `isShown`, but always taking its space.
    /// Inserting the row's icons on hover narrowed the row, the text wrapped, and
    /// the line jumped under the pointer.
    func hoverReveal(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}
