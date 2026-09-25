import SwiftUI
import MacBenchCore

/// The one thing this app can do that the Finder cannot: find a file because
/// somebody said something about it.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.searchResults.isEmpty {
            EmptyStateView(title: "Nothing found",
                           hint: "Search covers file names, folder names and every word either of you has written.")
        } else {
            List {
                if !model.searchResults.nodes.isEmpty {
                    Section("Files and folders") {
                        ForEach(model.searchResults.nodes) { node in
                            Button {
                                model.searchText = ""
                                model.focus(node: node)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: node.isDirectory ? "folder" : "doc")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(node.name)
                                            .strikethrough(node.state == .deleted)
                                            .foregroundStyle(node.state == .deleted ? .secondary : .primary)
                                        Text(node.relativePath)
                                            .font(.caption).foregroundStyle(.tertiary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    if node.state == .deleted {
                                        Text("deleted").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !model.searchResults.entries.isEmpty {
                    Section("Written about") {
                        ForEach(model.searchResults.entries) { item in
                            EntryRow(item: item, showsDay: true)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
