import SwiftUI
import MacBenchCore

struct FileListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.visibleFiles.isEmpty && model.visibleSubfolders.isEmpty {
            VStack(spacing: 8) {
                Text(emptyText)
                    .font(.callout).foregroundStyle(.tertiary)
                // The filter that emptied this list is in the sidebar, and the
                // header that offers the way out is gone with the last row.
                if model.sidebarFilter != .all {
                    Button("Show All Files") { model.sidebarFilter = .all }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Folders first, whatever the order is. They are the way
                    // down rather than something to read, and a folder whose
                    // date moves every time anything inside it is saved would
                    // wander through a list sorted by date.
                    ForEach(model.visibleSubfolders) { folder in
                        FolderRow(node: folder)
                        Divider().padding(.leading, 44)
                    }
                    ForEach(model.visibleFiles) { file in
                        FileRow(item: file)
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private var emptyText: LocalizedStringKey {
        switch model.sidebarFilter {
        case .all: "No files in this folder"
        case .unread: "Nothing unread in this folder"
        case .open: "No open tasks in this folder"
        }
    }
}

/// Where a picked row's colour stops. Short of the column's edges, and rounded:
/// drawn right up to the edge it ran into the sidebar, whose glass picked it up
/// and showed it again as a shadow along its border. The text stays where it
/// was — the inset comes out of the row's own padding — and so does the place
/// you can click: the gap beside the colour is still the row.
enum RowInset {
    static let edge: CGFloat = 6
    static let text: CGFloat = 16 - edge
    static let shape = RoundedRectangle(cornerRadius: 6)
}

/// The way one level down, in the column you are already looking at. It used to
/// appear only in a folder that had no files of its own, which made the list an
/// answer to "what is here" that left out half of what is here.
struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let node: Node
    @State private var isHovering = false

    var body: some View {
        Button {
            model.selection = .node(node.id)
            model.expanded.insert(.node(node.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .frame(width: 24).foregroundStyle(.secondary)
                Text(node.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                ModifiedDate(date: node.contentModifiedAt)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(isHovering ? .secondary : .tertiary)
            }
            .padding(.horizontal, RowInset.text)
            .padding(.vertical, 7)
            .background(isHovering ? Color.primary.opacity(0.04) : .clear, in: RowInset.shape)
            .padding(.horizontal, RowInset.edge)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Show in Finder") { model.reveal(node) }
        }
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: FileListItem
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        Button {
            model.selectedFile = model.selectedFile == item.node.id ? nil : item.node.id
        } label: {
            HStack(spacing: 10) {
                preview
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.node.name)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(item.node.state == .deleted ? .secondary : .primary)
                        .strikethrough(item.node.state == .deleted)
                    if let date = item.lastActivityAt {
                        HStack(spacing: 4) {
                            // The name in its colour, as everywhere else. A dot in
                            // front of it is where the list puts "unread", and read
                            // as that.
                            if let author = item.lastAuthor {
                                AuthorName(member: author)
                            }
                            Text(Format.timestamp(date))
                            // Only where the surroundings do not already say it: in a
                            // folder every row is the same project, and repeating it
                            // on every line is noise rather than information.
                            if spansProjects {
                                Text(projectName)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                // The same cluster, in the same order, as every other row in the
                // app: open, Finder, menu. It sits to the left of the date so that
                // the column of dates holds still while the pointer travels down
                // the list.
                RowActions(node: item.node) {
                    FileMenu(node: item.node, offersStream: true)
                }
                .hoverReveal(isHovering || isSelected)
                ModifiedDate(date: item.node.contentModifiedAt)
                if item.openTaskCount > 0 {
                    Image(systemName: "checkmark.circle")
                        .imageScale(.small).foregroundStyle(.secondary)
                }
                // How much is waiting, not just that something is. Seven unread
                // changes and one are a different decision about what to open next.
                if item.unreadCount > 1 {
                    Text(item.unreadCount, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                if item.unreadCount > 0 {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, RowInset.text)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RowInset.shape)
            .padding(.horizontal, RowInset.edge)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // What a double click does to a file is open it. That is the one thing
        // every Mac already knows about a list of files, and it used to be the
        // gesture that showed and hid a column instead — which is what the
        // row's menu is for. Lines about a file open it the same way.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selectedFile = item.node.id
            model.open(item.node)
        })
        .contextMenu { FileMenu(node: item.node, offersStream: true) }
        // Again when the file changes, not only when the row is a different file.
        .task(id: "\(item.node.id)@\(item.node.contentModifiedAt?.timeIntervalSinceReferenceDate ?? 0)") {
            await loadThumbnail()
        }
    }

    private var isSelected: Bool { model.selectedFile == item.node.id }

    private var spansProjects: Bool {
        if case .activity = model.selection { return true }
        return false
    }

    private var projectName: String {
        model.projects.first { $0.id == item.node.projectID }?.name ?? ""
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(.rect(cornerRadius: 3))
        } else {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        guard let url = model.url(for: item.node) else { return "doc" }
        // A file iCloud has not put on this Mac gets a cloud icon and no preview
        // request — asking for one would start downloading it.
        return ThumbnailCache.shared.isMaterialised(url) ? "doc" : "icloud.and.arrow.down"
    }

    private func loadThumbnail() async {
        guard item.node.state == .present, let url = model.url(for: item.node) else { return }
        thumbnail = await ThumbnailCache.shared.thumbnail(for: url,
                                                          size: CGSize(width: 48, height: 48))
    }
}

/// When the file itself last changed — the question the list is sorted by, so it
/// is on the row rather than only in the sort menu. A fixed width, right
/// aligned: the dates are read as a column, and a column that is not a column
/// cannot be scanned.
struct ModifiedDate: View {
    let date: Date?

    var body: some View {
        Text(date.map { Format.timestamp($0) } ?? "—")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: 92, alignment: .trailing)
            .help(date.map { Text("Last changed: \($0.formatted(date: .long, time: .shortened))") }
                  ?? Text("No modification date on record"))
    }
}

/// What a file offers, in words, for the menus. The row shows the same things as
/// icons; nobody should have to learn which of the two a list happens to use.
struct FileMenu: View {
    @Environment(AppModel.self) private var model
    let node: Node
    /// In the file list beside the stream column: the way to what was said about it.
    var offersStream = false

    var body: some View {
        if offersStream {
            StreamMenuButton(isShowingThis: model.selectedFile == node.id && model.isStreamVisible,
                             showTitle: "Show File History") {
                model.selectedFile = node.id
            }
            Divider()
        }
        Button("Open") { model.open(node) }
        if model.canOpenInMarkEdit(node) {
            Button("Open in MarkEdit") { model.openInMarkEdit(node) }
        }
        if model.isEvicted(node) {
            Button("Download and Quick Look") { model.downloadAndPreview(node) }
        } else {
            Button("Quick Look") { model.toggleQuickLook(node) }
                .disabled(!model.canQuickLook(node))
        }
        Button("Show in Finder") { model.reveal(node) }
    }
}
