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
                            // Picked like a line in the feed: the column beside
                            // it then shows what was said around it.
                            EntryRow(item: item, selectable: false, showsDay: true)
                                .padding(.horizontal, 8)
                                .background(background(for: item), in: .rect(cornerRadius: 6))
                                .animation(.easeOut(duration: 0.45), value: model.flashingEntry)
                                .contentShape(.rect)
                                .onTapGesture(count: 2) {
                                    model.searchPick = item
                                    if let node = item.node, !node.isPlaceholder { model.open(node) }
                                }
                                .onTapGesture {
                                    model.searchPick = item
                                    model.isStreamVisible = true
                                }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func background(for item: TimelineItem) -> Color {
        if model.flashingEntry == item.id { return .accentColor.opacity(0.28) }
        if model.searchPick?.id == item.id { return .accentColor.opacity(0.12) }
        return .clear
    }
}
