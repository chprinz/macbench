import SwiftUI
import MacBenchCore

/// Reachable from anywhere with the global shortcut, including while another app
/// is in front. Nothing to navigate: pick the project, say the thing, done.
struct QuickCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var projectID: UUID?
    @State private var isTask = false
    @State private var justSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $projectID) {
                    ForEach(model.projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Toggle(isOn: $isTask) {
                    Label("Task", systemImage: isTask ? "checkmark.square.fill" : "square")
                }
                .toggleStyle(.button)
                .controlSize(.small)

                Spacer()
                if justSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            TextField("Quick note…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(2...5)
                .focused($isFocused)
                .onReturnKey(perform: save)

            HStack {
                Text("Return to save · Esc to close")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            // A project removed since the last note would leave the picker blank
            // and the note with nowhere to go.
            if let projectID, !model.projects.contains(where: { $0.id == projectID }) {
                self.projectID = nil
            }
            projectID = projectID ?? model.currentProjectID ?? model.projects.first?.id
            isFocused = true
        }
        .onExitCommand { dismiss() }
        .animation(.default, value: justSaved)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let projectID else { return }
        // "Saved" is only said about something that was.
        guard model.isWatching(projectID) else { NSSound.beep(); return }
        let task = isTask
        // The same rule as the composer: @name makes it for that person, and
        // tells them. A quick note used to drop the name on the floor.
        let recipient = Mentions.recipient(in: trimmed, members: model.members)?.id
        text = ""
        isTask = false
        Task {
            let kept = await model.post(text: trimmed, projectID: projectID, nodeID: nil,
                                        isTask: task, assignee: recipient, categories: [])
            guard kept else {
                if text.isEmpty { text = trimmed; isTask = task }
                NSSound.beep()
                return
            }
            justSaved = true
            try? await Task.sleep(for: .milliseconds(700))
            justSaved = false
            dismiss()
        }
    }
}
