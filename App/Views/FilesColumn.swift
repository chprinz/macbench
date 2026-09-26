import SwiftUI
import QuickLook
import MacBenchCore

/// The middle column: the list you came for. Files in a folder, the tasks, or
/// everything that has happened — one rule, so that the widest column is never
/// the one answering the side question.
struct FilesColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.searchText.isEmpty {
                SearchResultsView()
            } else {
                switch model.selection {
                case .openTasks: TaskListView()
                case .activity: ActivityColumn()
                case .project, .node:
                    header
                    Divider()
                    FileListView()
                }
            }
        }
        .background(.background)
        // The preview panel belongs to the column rather than to the list inside
        // it: the file stays picked while the folder is re-read, and a panel that
        // closed itself every time anything changed would be unusable.
        .quickLookPreview($model.quickLookURL)
        .quickLookOnSpaceBar()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            PathBar()
            if let contents {
                HStack(spacing: 8) {
                    Text(contents)
                        .font(.caption).foregroundStyle(.tertiary)
                    if let narrowing {
                        // The filter sits in the sidebar, out of sight of this
                        // list. Without a word here a folder that shows two of
                        // its forty files reads as a folder with two files.
                        Button {
                            model.sidebarFilter = .all
                        } label: {
                            Label(narrowing, systemImage: "line.3.horizontal.decrease.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("The filter above the projects in the sidebar applies here too. Click to show everything again.")
                    }
                    Spacer(minLength: 8)
                    SortMenu()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// What is in this folder, in one line — both kinds, because both are now in
    /// the list below it and a count that mentions one of them reads as a bug.
    private var contents: LocalizedStringKey? {
        let folders = model.visibleSubfolders.count
        let files = model.visibleFiles.count
        return switch (folders, files) {
        case (0, 0): nil
        case (0, _): "\(files) files"
        case (_, 0): "\(folders) folders"
        default: "\(folders) folders, \(files) files"
        }
    }

    private var narrowing: LocalizedStringKey? {
        switch model.sidebarFilter {
        case .all: nil
        case .unread: "Only unread"
        case .open: "Only with open tasks"
        }
    }
}

/// Everything that has happened, in the widest column, because reading it is
/// what this view is for. The column beside it is then free to be what it is
/// everywhere else: the conversation around the one line you picked.
struct ActivityColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                PathBar()
                ProjectChips(selection: Bindable(model).filter.project)
                FilterBar()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
            TimelineView(items: model.activity,
                         emptyTitle: "Nothing has happened yet",
                         emptyHint: "Everything that happens in any of your projects lands here — what people write, and the file changes that were noticed. What you have not read is marked, and the list opens at the first of it.",
                         selectsRows: true,
                         reachesFurther: model.activityIsCut,
                         showEarlier: { model.showEarlierActivity() })
        }
    }
}

/// The right column: what was said, and the field to say something.
struct StreamColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TimelineView(items: model.timeline, emptyTitle: emptyTitle, emptyHint: emptyHint,
                         reachesFurther: model.timelineIsCut,
                         showEarlier: { model.showEarlierStream() })
            if model.currentProjectID != nil {
                Divider()
                ComposerView()
            }
        }
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCrossProjectList {
                // Beside a list that spans projects this column is not a list of
                // its own: it is the conversation the selected line belongs to,
                // unfiltered, with the field to answer it at the bottom.
                entryContext
            } else {
                fileOrFolderHeader
                FilterBar()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var isCrossProjectList: Bool {
        if model.isSearching { return true }
        return switch model.selection {
        case .openTasks, .activity: true
        case .project, .node: false
        }
    }

    private var entryContext: some View {
        HStack(spacing: 6) {
            if let entry = model.contextEntry {
                Image(systemName: model.selectedNode.map { $0.isDirectory ? "folder" : "doc.text" } ?? "folder")
                    .foregroundStyle(Color.accentColor)
                Text(model.selectedNode?.name ?? projectName(entry))
                    .font(.headline)
                    // Two lines rather than a name cut in the middle: these are
                    // "26-09-07 Kunde A Erstgespräch_Zusammenfassung.txt", and
                    // the part that identifies it is at both ends.
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            // Nothing selected needs no heading: the empty state below already
            // says what this column is waiting for, and saying it twice in one
            // narrow column reads as a bug.
            Spacer(minLength: 0)
            SyncIndicator()
        }
    }

    private func projectName(_ item: TimelineItem) -> String {
        model.projects.first { $0.id == item.entry.projectID }?.name ?? ""
    }

    private var fileOrFolderHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Narrowing the stream to one file or folder changes what everything
            // below means, so it gets a heading rather than a small chip that is
            // easy to read past. The way back out is a labelled button, not an × .
            if let picked = model.selectedNode {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: picked.isDirectory ? "folder" : "doc.text")
                            .foregroundStyle(Color.accentColor)
                        Text(picked.name)
                            .font(.headline)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        SyncIndicator()
                    }
                    // The way back is only a folder when you came from one.
                    Button {
                        model.selectedNodeID = nil
                    } label: {
                        Label("Show the whole folder", systemImage: "arrow.up.left")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 8))
            } else {
                HStack(spacing: 8) {
                    Text("Everything in this folder")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    SyncIndicator()
                }
            }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        if model.isSearching {
            return model.searchPick == nil ? "Pick a result" : nothingAboutPicked
        }
        return switch model.selection {
        case .openTasks: model.selectedEntry == nil ? "Pick a task" : nothingAboutPicked
        case .activity: model.selectedEntry == nil ? "Pick an entry" : nothingAboutPicked
        case .project, .node:
            model.selectedNodeID == nil ? "No changes yet" : nothingAboutPicked
        }
    }

    private var nothingAboutPicked: LocalizedStringKey {
        model.selectedNode?.isDirectory == true ? "Nothing about this folder yet" : "Nothing about this file yet"
    }

    private var emptyHint: LocalizedStringKey {
        if model.isSearching {
            return model.searchPick == nil
                ? "Pick one on the left and this shows what was said around it — the file it is about, and the changes to it. An answer is written here too."
                : "Write the first note below."
        }
        return switch model.selection {
        case .openTasks, .activity: model.selectedEntry == nil
            ? "Pick one on the left and this shows what was said around it — the file it is about, and the changes to it. An answer is written here too."
            : "Write the first note below."
        case .project, .node: model.selectedNodeID == nil
            ? "Files that were already here were indexed without entries. From now on, every change lands here — quiet ones after they have been gathered for twenty minutes."
            : "Write the first note below."
        }
    }
}
