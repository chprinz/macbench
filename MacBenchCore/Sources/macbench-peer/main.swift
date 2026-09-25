import Foundation
import MacBenchCore

// A second Mac, on the command line.
//
// The cases this app exists for need two machines: a message arriving from the
// other person, a task given to you from over there, somebody joining a folder
// that already has a history, a name changed on the other side, a log that is
// behind. This plays the other Mac against the same folder — its own index, its
// own identity, its own device folder in `.macbench` — so all of that can be
// tried against the real app on one Mac. It runs the same engine the app does;
// nothing here is a mock of it.
//
// Use a throwaway folder (`sample` makes one). Whatever this writes into a
// folder's `.macbench` stays in that folder's history, as it would from a real
// second Mac.

let usage = """
    Usage: swift run macbench-peer <command> [arguments] [--as <name>]

      sample <folder>            make a small project folder to try things in
      watch  <folder> [--files]  join the folder as another Mac and print what
                                 arrives, until Ctrl-C. Messages only, unless
                                 --files: on the Mac the app runs on, both would
                                 claim every change made to a file there
      say    <folder> <text>     write a message. @Name in the text addresses it;
                                 --task makes it a task, --file <path> puts it on
                                 a file (relative to the folder)
      tick   <folder> <text>     tick off the first open task containing <text>
      rename <folder> <name>     change this person's name, as Settings does
      show   <folder> [count]    the last lines as this Mac sees them, and how far
                                 it has read each other Mac's log
      reset                      forget this Mac: its index and identity. What it
                                 wrote into folders stays there.

      --as <name>   who this Mac is; default Ben. Each name is a Mac of its own,
                    kept in ~/Library/Application Support/MacBench Peer/<name>

    """

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Arguments

struct Arguments {
    var command = ""
    var positional: [String] = []
    var name = "Ben"
    var isTask = false
    var file: String?
    var watchesFiles = false

    init(_ raw: [String]) throws {
        var rest = raw[...]
        guard let command = rest.popFirst() else { throw Failure(usage) }
        self.command = command
        while let argument = rest.popFirst() {
            switch argument {
            case "--as":
                guard let value = rest.popFirst() else { throw Failure("--as needs a name") }
                name = value
            case "--task": isTask = true
            case "--files": watchesFiles = true
            case "--file":
                guard let value = rest.popFirst() else { throw Failure("--file needs a path") }
                file = value
            case "-h", "--help": throw Failure(usage)
            default: positional.append(argument)
            }
        }
    }

    /// The folder, spelled the way FSEvents will report it. Given as /tmp/x the
    /// events arrive for /private/tmp/x, match nothing, and the peer hears
    /// nothing — the same trap the integration tests document.
    func folder() throws -> URL {
        guard let path = positional.first else { throw Failure("Which folder?\n\n" + usage) }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
        return URL(fileURLWithPath: canonical ?? url.path(percentEncoded: false), isDirectory: true)
    }

    /// Everything after the folder, as one piece of text.
    var text: String { positional.dropFirst().joined(separator: " ") }
}

// MARK: - The simulated Mac

struct Peer {
    static let identityKey = "local.identity"
    /// The app's own palette, so a simulated person looks like a real one.
    static let palette = ["#E4572E", "#2E86AB", "#5B8C5A", "#8367C7",
                          "#C77D3E", "#3E8E7E", "#B5446E", "#4B6584"]

    let home: URL
    let store: Store
    var identity: LocalIdentity

    static func home(for name: String) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "MacBench Peer", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

    init(name: String) throws {
        home = Peer.home(for: name)
        store = try Store(url: home.appending(path: "index.sqlite"))
        if let stored = try store.setting(Peer.identityKey, as: LocalIdentity.self) {
            identity = stored
        } else {
            // Stable, unlike hashValue, so a name gets the same colour every time.
            let seed = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            let colour = Peer.palette[seed % Peer.palette.count]
            identity = LocalIdentity(deviceName: "\(name)’s simulated Mac",
                                     member: Member(name: name, colorHex: colour))
            try store.setSetting(Peer.identityKey, value: identity)
        }
        try store.upsert(member: identity.member)
    }

    func project(for folder: URL) throws -> Project {
        let path = folder.path(percentEncoded: false)
        for project in try store.projects(includeArchived: true)
        where try store.projectLocation(project.id)?.path == path {
            return project
        }
        let project = Project(name: folder.lastPathComponent)
        try store.addProject(project, rootPath: path, bookmark: nil)
        return project
    }

    /// The engine for a folder, having joined it the way a Mac does the first
    /// time — a silent look at every file, and one line saying who joined — and
    /// having read what the others wrote since. The watcher is not left running:
    /// on the Mac the app runs on, it would claim the app's changes as its own.
    func open(_ folder: URL) async throws -> (engine: ProjectEngine, project: Project) {
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            throw Failure("No folder at \(folder.path(percentEncoded: false))")
        }
        let project = try project(for: folder)
        let engine = try ProjectEngine(projectID: project.id, root: folder, store: store,
                                       identity: identity, supportDirectory: home)
        if try store.fsEventCursor(for: project.id).lastScanAt == nil {
            await engine.start()
            await engine.stop()
        }
        await engine.pullPeers()
        return (engine, project)
    }

    func lines(in project: Project, count: Int) throws -> [TimelineItem] {
        var filter = TimelineFilter()
        filter.limit = count
        return try store.timeline(scope: .project(project.id), filter: filter,
                                  viewer: identity.member.id)
    }

    func health(of project: Project) throws -> [String] {
        try store.peers(for: project.id).map { peer in
            let who = try peer.memberID.flatMap(store.member(id:))?.name ?? peer.deviceName ?? "?"
            let read = "read \(peer.appliedSequence) of \(peer.claimedSequence) records"
            return "  \(who) (\(peer.deviceName ?? "unknown Mac")): \(read)"
                + (peer.isBehind ? " — behind, waiting for sync" : "")
        }
    }
}

// MARK: - Output

func describe(_ item: TimelineItem) -> String {
    let time = item.entry.createdAt.formatted(date: .omitted, time: .shortened)
    let who = item.author?.name ?? "Someone"
    if item.entry.notice == .joined { return "\(time)  \(who) joined" }
    if let event = item.entry.event {
        let file = item.node.map { $0.isPlaceholder ? "a file not known here yet" : $0.relativePath }
            ?? "a file"
        let verb = switch event.type {
        case .created: "added"
        case .modified: "changed"
        case .renamed: "renamed"
        case .moved: "moved"
        case .removed: "deleted"
        }
        return "\(time)  \(who) \(verb) \(file)" + (event.backfilled ? "  (reconstructed)" : "")
    }
    var line = "\(time)  "
    if item.entry.isTask { line += item.entry.isDone ? "[x] " : "[ ] " }
    line += "\(who): \(item.entry.text)"
    if let assignee = item.assignee { line += "  → \(assignee.name)" }
    if let node = item.node, !node.isPlaceholder { line += "  (on \(node.relativePath))" }
    return line
}

/// Ctrl-C, as something to wait for.
func interruption() -> AsyncStream<Void> {
    AsyncStream { continuation in
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT)
        source.setEventHandler {
            continuation.yield()
            continuation.finish()
        }
        source.resume()
        continuation.onTermination = { _ in source.cancel() }
    }
}

// MARK: - Commands

func makeSample(at folder: URL) throws {
    let manager = FileManager.default
    let path = RelativePath.normalize(folder.path(percentEncoded: false)).isEmpty
        ? "/" : "/" + RelativePath.normalize(folder.path(percentEncoded: false))
    if manager.fileExists(atPath: path), !(try manager.contentsOfDirectory(atPath: path)).isEmpty {
        throw Failure("\(path) is not empty. The sample goes into a new or empty folder.")
    }
    let files: [(String, String)] = [
        ("Brief/brief.txt", "Client brief\n\nA2 poster, logo, and a leaflet.\nDeadline: Friday.\n"),
        ("Brief/schedule.txt", "Mon  kickoff\nWed  first drafts\nFri  print data\n"),
        ("Logo/logo-notes.txt", "Keep the mark legible at 16 px.\n"),
        ("Poster/poster-a2.txt", "Headline\nSubline\nDate and place\n"),
        // A document that is a folder on disk: one file to the app, never its insides.
        ("Poster/Proposal.pages/Index.zip", "not really a zip\n"),
        ("Poster/Proposal.pages/preview.jpg", "not really a jpeg\n"),
        // An application cache: never indexed, never reported.
        ("Footage/CacheClip/render-0001.cache", "noise\n"),
    ]
    for (relative, contents) in files {
        let url = folder.appending(path: relative)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    print("""
        Made a sample project at \(path)

        Next:
          1. Add it in the app (⇧⌘O), as yourself.
          2. swift run macbench-peer watch "\(path)"
             Ben joins it; write something in the app and it arrives here.
          3. swift run macbench-peer say "\(path)" "@YourName can you check the brief?" --task --file Brief/brief.txt
             A task for you, from Ben, on a file — the app notifies you.
        """)
}

func watch(_ peer: Peer, folder: URL, watchesFiles: Bool) async throws {
    let (engine, project) = try await peer.open(folder)
    if watchesFiles { await engine.start() }
    print("\(peer.identity.member.name) is in \(project.name)"
          + (watchesFiles ? ", watching its files too" : "") + ". Ctrl-C to stop.\n")

    let stop = interruption()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await _ in stop { return }
        }
        group.addTask {
            var seen = Set<UUID>()
            var lastHealth: [String] = []
            while !Task.isCancelled {
                if !watchesFiles { await engine.pullPeers() }
                for item in (try? peer.lines(in: project, count: 200)) ?? [] where !seen.contains(item.id) {
                    seen.insert(item.id)
                    print(describe(item))
                }
                let health = (try? peer.health(of: project)) ?? []
                if health != lastHealth, health.contains(where: { $0.contains("behind") }) {
                    print(health.joined(separator: "\n"))
                }
                lastHealth = health
                try? await Task.sleep(for: .seconds(1))
            }
        }
        await group.next()
        group.cancelAll()
    }
    if watchesFiles { await engine.stop() }
    print("\nStopped.")
}

func run() async throws {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))

    switch arguments.command {
    case "sample":
        try makeSample(at: try arguments.folder())

    case "reset":
        let home = Peer.home(for: arguments.name)
        try? FileManager.default.removeItem(at: home)
        print("Forgot \(arguments.name). What it wrote into folders stays there.")

    case "watch":
        try await watch(try Peer(name: arguments.name), folder: try arguments.folder(),
                        watchesFiles: arguments.watchesFiles)

    case "say":
        let peer = try Peer(name: arguments.name)
        let text = arguments.text
        guard !text.isEmpty else { throw Failure("What should \(arguments.name) say?") }
        let (engine, project) = try await peer.open(try arguments.folder())
        var nodeID: UUID?
        if let file = arguments.file {
            guard let node = try peer.store.node(projectID: project.id,
                                                 relativePath: RelativePath.normalize(file)) else {
                throw Failure("\(file) is not a file \(arguments.name)'s Mac knows in \(project.name)")
            }
            nodeID = node.id
        }
        let recipient = Mentions.recipient(in: text, members: try peer.store.members())
        let entry = try await engine.post(text: text, nodeID: nodeID, isTask: arguments.isTask,
                                          assignee: recipient?.id)
        if let said = try peer.lines(in: project, count: 50).first(where: { $0.id == entry.id }) {
            print(describe(said))
        }

    case "tick":
        let peer = try Peer(name: arguments.name)
        let needle = arguments.text.lowercased()
        let (engine, project) = try await peer.open(try arguments.folder())
        var filter = TimelineFilter.tasks
        filter.project = project.id
        let open = try peer.store.timeline(scope: .openTasks, filter: filter, viewer: peer.identity.member.id)
        guard let task = open.first(where: { needle.isEmpty || $0.entry.text.lowercased().contains(needle) })
        else { throw Failure("No open task in \(project.name) says “\(arguments.text)”") }
        try await engine.patch(EntryPatchRecord(entryID: task.id, isDone: true))
        print("Ticked off: \(task.entry.text)")

    case "rename":
        var peer = try Peer(name: arguments.name)
        let newName = arguments.text
        guard !newName.isEmpty else { throw Failure("Rename \(arguments.name) to what?") }
        let (engine, _) = try await peer.open(try arguments.folder())
        peer.identity.member.name = newName
        try peer.store.setSetting(Peer.identityKey, value: peer.identity)
        try peer.store.upsert(member: peer.identity.member)
        try await engine.update(member: peer.identity.member)
        print("\(arguments.name) is now called \(newName) in this folder's log. "
              + "Keep using --as \(arguments.name) for this Mac.")

    case "show":
        let peer = try Peer(name: arguments.name)
        let count = arguments.positional.dropFirst().first.flatMap(Int.init) ?? 20
        let (_, project) = try await peer.open(try arguments.folder())
        for item in try peer.lines(in: project, count: count) { print(describe(item)) }
        let health = try peer.health(of: project)
        print(health.isEmpty ? "\nNo other Mac has written into this folder yet."
                             : "\nOther Macs:\n" + health.joined(separator: "\n"))

    default:
        throw Failure(usage)
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
