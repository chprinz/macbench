import SwiftUI
import UniformTypeIdentifiers
import MacBenchCore

/// The bottom of every view. It stays in one place and keeps its focus, because
/// people dictate straight into it and a field that moves or loses focus
/// mid-sentence is worse than no field at all.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var isTask = false
    @State private var assignee: UUID?
    @State private var categories: Set<UUID> = []
    @State private var attachedNode: Node?
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = model.replyTarget {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left").font(.caption)
                    Text("Replying to \(target.author?.name ?? String(localized: "Unknown")): \(target.entry.text)")
                        .font(.caption).lineLimit(1).truncationMode(.tail)
                    Button {
                        model.replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
            if let attachedNode {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.caption)
                    Text(attachedNode.relativePath).font(.caption).lineLimit(1).truncationMode(.middle)
                    Button {
                        self.attachedNode = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField(prompt, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .font(.body)
                    .onReturnKey(perform: send)

                HStack(spacing: 8) {
                Toggle(isOn: $isTask) {
                    Label("Task", systemImage: isTask ? "checkmark.square.fill" : "square")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Turns this message into a task. Open tasks collect under Tasks in the sidebar until somebody ticks them off.")

                if !model.categories.isEmpty {
                    CategoryPicker(selected: $categories)
                }

                // Not gated on the checkbox: who a message is for and whether it is
                // a piece of work are two different questions. Addressing somebody
                // without a task is a heads-up; with one it is work.
                Menu {
                    Button("Nobody in particular") { assignee = nil }
                    ForEach(model.members) { member in
                        Button(member.name) { assignee = member.id }
                    }
                } label: {
                    if let recipient = effectiveRecipient {
                        Label(recipient.name, systemImage: "at")
                            .foregroundStyle(Color(hex: recipient.colorHex))
                    } else {
                        Label("For", systemImage: "at")
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("Who this is for. Typing @ and a name in the text does the same thing.")

                Spacer(minLength: 0)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(.quaternary.opacity(isDropTarget ? 0.5 : 0.25), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isDropTarget ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls.first)
            return true
        } isTargeted: { isDropTarget = $0 }
        .onChange(of: model.selection) { _, _ in attachedNode = defaultNode }
        .onChange(of: model.selectedFile) { _, _ in attachedNode = defaultNode }
        .onAppear { attachedNode = defaultNode }
    }

    private var prompt: LocalizedStringKey {
        attachedNode == nil ? "Write something…" : "Write something about this file…"
    }

    private var defaultNode: Node? { model.selectedFileNode }

    /// A name picked from the menu wins; otherwise whoever the text names. Typing
    /// "@Mara schau mal" should not also require finding a menu.
    private var effectiveRecipient: Member? {
        if let assignee { return model.members.first { $0.id == assignee } }
        return Mentions.recipient(in: text, members: model.members)
    }

    private func attach(_ url: URL?) {
        guard let url else { return }
        attachedNode = model.node(forDroppedURL: url)
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let projectID = model.currentProjectID else { return }
        // Kept in the field rather than sent nowhere. The banner says why.
        guard model.isWatching(projectID) else { NSSound.beep(); return }
        let node = attachedNode?.id
        let task = isTask
        let picked = assignee
        let who = effectiveRecipient?.id
        let tags = categories
        let reply = model.replyTarget
        text = ""
        isTask = false
        assignee = nil
        categories = []
        model.replyTarget = nil
        Task {
            let kept = await model.post(text: trimmed, projectID: projectID, nodeID: node,
                                        isTask: task, assignee: who, categories: tags,
                                        replyTo: reply?.entry.id)
            // Writing it failed: the words come back, unless something new has
            // been typed in the meantime.
            guard !kept, text.isEmpty else { return }
            text = trimmed
            isTask = task
            assignee = picked
            categories = tags
            model.replyTarget = reply
        }
    }
}

struct CategoryPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: Set<UUID>

    var body: some View {
        Menu {
            ForEach(model.categories) { category in
                Button {
                    if selected.contains(category.id) { selected.remove(category.id) }
                    else { selected.insert(category.id) }
                } label: {
                    HStack {
                        Text(Format.categoryName(category))
                        if selected.contains(category.id) { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Image(systemName: selected.isEmpty ? "tag" : "tag.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Categories")
    }
}
