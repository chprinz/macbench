import SwiftUI
import MacBenchCore

/// First launch. Three things are needed and nothing else is asked: who you are,
/// which folder to watch, and whether to start with the Mac.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = NSFullUserName().isEmpty ? "" : NSFullUserName()
    @State private var colorHex = MemberPalette.colors[0]
    @State private var deviceName = Host.current().localizedName ?? "This Mac"
    @State private var step = 0
    @State private var pickedFolder: URL?
    @State private var launchAtLogin = true
    @State private var knownMembers: [Member] = []
    @State private var joiningAs: Member?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: 460)
                .padding(40)
            Divider()
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                Button(step == 2 ? "Start" : "Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: folderStep
        default: identityStep
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Brand.name).font(.largeTitle.weight(.semibold))
            Text("Watches shared project folders. Records what changed, when, by whom, and what was written about it.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Row(symbol: "folder", title: "Not a file manager",
                    detail: "Moves, renames and deletes nothing. That stays the Finder's job.")
                Row(symbol: "network.slash", title: "No account, no server",
                    detail: "History is a JSON log in .macbench/ inside the project folder, synced the same way the files are: iCloud, Dropbox, NAS.")
                Row(symbol: "clock", title: "The index starts empty",
                    detail: "Existing files are indexed without creating entries. Logging starts now.")
            }
            .padding(.top, 6)
        }
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a project folder").font(.title2.weight(.semibold))
            Text("A folder that exists on both Macs. More can be added later.")
                .foregroundStyle(.secondary)
            Button {
                pickedFolder = FolderPicker.chooseProjectFolder()
                Task { await loadKnownMembers() }
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text(pickedFolder?.lastPathComponent ?? String(localized: "Choose Folder…"))
                    Spacer()
                }
                .padding(10)
            }
            .buttonStyle(.bordered)

            if !knownMembers.isEmpty {
                Text("Somebody is already keeping a history in this folder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Who are you?").font(.title2.weight(.semibold))

            if !knownMembers.isEmpty {
                // Joining as an existing person matters when someone adds a second
                // Mac: without it they would appear twice in their own history.
                Picker("", selection: $joiningAs) {
                    Text("Someone new").tag(nil as Member?)
                    ForEach(knownMembers) { member in
                        Text(member.name).tag(member as Member?)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if joiningAs == nil {
                Form {
                    TextField("Name", text: $name)
                    LabeledContent("Colour") { ColorSwatchPicker(selection: $colorHex) }
                    TextField("This Mac is called", text: $deviceName)
                }
                .formStyle(.grouped)
            }

            Toggle("Start at login", isOn: $launchAtLogin)
            Text("Recommended. Changes are captured live only while the app runs; otherwise they are reconstructed by comparing the folder, with approximate timestamps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canAdvance: Bool {
        switch step {
        case 1: pickedFolder != nil
        case 2: joiningAs != nil || !name.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }

    private func advance() {
        guard step == 2 else { step += 1; return }
        Task {
            if launchAtLogin { try? LaunchAtLogin.set(true) }
            await model.completeOnboarding(name: name, colorHex: colorHex,
                                           deviceName: deviceName, existingMember: joiningAs)
            if let pickedFolder { await model.addProject(url: pickedFolder) }
        }
    }

    private func loadKnownMembers() async {
        guard let folder = pickedFolder else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        knownMembers = DeviceLogReader.peers(in: folder).compactMap { $0.manifest?.member }
        if let first = knownMembers.first { colorHex = MemberPalette.next(after: [first.colorHex]) }
    }

    private struct Row: View {
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
