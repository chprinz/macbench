import Foundation
import Testing
@testable import MacBenchCore

/// One folder, two Macs, each with its own index and its own engine. This is
/// the state every shared project is in from the day the second person installs
/// the app, and the one the other suites only reach through a bare `PeerSync`.
@Suite("A second Mac on the same folder", .serialized)
struct SecondMacTests {

    /// One Mac's view of the shared folder: its own store, its own person, its
    /// own engine, and its own working files outside the folder.
    private struct Mac {
        let store: Store
        let identity: LocalIdentity
        let project: Project
        let engine: ProjectEngine

        init(_ name: String, colorHex: String = "#2E86AB", folder: URL, support: URL) throws {
            store = try Store()
            identity = LocalIdentity(deviceName: "\(name)s Mac",
                                     member: Member(name: name, colorHex: colorHex))
            try store.upsert(member: identity.member)
            project = Project(name: "Kunde A")
            try store.addProject(project, rootPath: folder.path(percentEncoded: false), bookmark: nil)
            engine = try ProjectEngine(projectID: project.id, root: folder, store: store,
                                       identity: identity,
                                       supportDirectory: support.appending(path: name))
        }

        func timeline() throws -> [TimelineItem] {
            var filter = TimelineFilter()
            filter.limit = 1000
            return try store.timeline(scope: .project(project.id), filter: filter,
                                      viewer: identity.member.id)
        }

        /// Everything that is about a file rather than about a person joining.
        func changes() throws -> [TimelineItem] {
            try timeline().filter { $0.entry.event != nil }
        }

        func node(_ path: String) throws -> Node? {
            try store.node(projectID: project.id, relativePath: path)
        }

        /// The changes this Mac itself put in its log, as the other Mac reads them.
        func changesWritten(in folder: Folder) -> [EntryRecord] {
            guard let own = DeviceLogReader.peers(in: folder.root)
                .first(where: { $0.deviceID == identity.deviceID }) else { return [] }
            return DeviceLogReader.read(peer: own, after: 0).records.compactMap { record in
                if case .entry(let entry) = record.body, entry.event != nil { entry } else { nil }
            }
        }
    }

    private struct Folder {
        let root: URL
        let support: URL

        init() throws {
            // Canonical, for the reason `EngineIntegrationTests` gives: the /var
            // symlink sends the scanner down a branch the app never takes.
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
            let path = (try? base.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
            root = URL(fileURLWithPath: path ?? base.path(percentEncoded: false), isDirectory: true)
                .appending(path: "macbench-two-\(UUID().uuidString)", directoryHint: .isDirectory)
            support = base.appending(path: "macbench-two-support-\(UUID().uuidString)",
                                     directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func write(_ relativePath: String, _ contents: String) throws {
            let url = root.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func move(_ from: String, to: String) throws {
            try FileManager.default.moveItem(at: root.appending(path: from),
                                             to: root.appending(path: to))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: support)
        }
    }

    /// The second person installs the app weeks after the first and adds the
    /// same folder. Its log already registers every file, and reading that log
    /// first used to make the folder look known: instead of a silent first look,
    /// the new Mac compared the folder against files it had never seen, and
    /// reported every one of them as changed — to itself and, through its log,
    /// to the first Mac as well.
    @Test("Joining a folder with a history is as quiet as the first look at it")
    func joiningIsSilent() async throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        try folder.write("Layout/plakat.txt", "eins\n")
        try folder.write("Text/angebot.txt", "alt\n")
        try folder.write("Text/brief.txt", "Sehr geehrte\n")

        let anna = try Mac("Anna", colorHex: "#E4572E", folder: folder.root, support: folder.support)
        await anna.engine.start()
        // Versioning by renaming, before the second Mac ever saw the file: the
        // log now registers an id derived from the old name at the new one.
        try folder.move("Text/brief.txt", to: "Text/brief_v1.txt")
        await anna.engine.rescan()
        await anna.engine.stop()

        let ben = try Mac("Ben", folder: folder.root, support: folder.support)
        await ben.engine.start()
        #expect(ben.changesWritten(in: folder).isEmpty,
                "files that were already there are not news to the person joining")
        #expect(try ben.changes().allSatisfy { $0.author?.name == "Anna" },
                "what Ben does see about files is Anna's history from before he came")
        let joined = try ben.timeline().filter { $0.entry.notice == .joined }
        #expect(Set(joined.compactMap(\.author?.name)) == ["Anna", "Ben"],
                "what it does say is who is in the folder, both of them")

        for path in ["Layout/plakat.txt", "Text/angebot.txt", "Text/brief_v1.txt"] {
            let node = try #require(try ben.node(path), "\(path) must be indexed")
            #expect(node.contentModifiedAt != nil, "\(path) must be indexed as this disk has it")
        }
        #expect(try ben.node("Text/brief_v1.txt")?.id == Namespace.nodeID(firstSeenPath: "Text/brief.txt"),
                "and under the id the other Mac uses for it, so both mean the same file")

        await ben.engine.rescan()
        #expect(ben.changesWritten(in: folder).isEmpty, "a later look finds nothing to report either")
        await ben.engine.stop()

        // And the first Mac hears nothing about files it already had.
        await anna.engine.start()
        #expect(try anna.changes().allSatisfy { $0.author?.name == "Anna" },
                "the second Mac must not have written a change of its own")
        await anna.engine.stop()
    }

    /// Settings says a new name travels in the log and the other Mac picks it up
    /// by itself. It did not: the engine kept the name it was started with, sent
    /// that again, and the manifest put the old name back on every read.
    @Test("A new name reaches the other Mac and stays there")
    func renameTravels() async throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        try folder.write("a.txt", "eins\n")

        let anna = try Mac("Anna", colorHex: "#E4572E", folder: folder.root, support: folder.support)
        await anna.engine.start()
        var renamed = anna.identity.member
        renamed.name = "Anna-Lena"
        renamed.colorHex = "#5B8C5A"
        try await anna.engine.update(member: renamed)

        let ben = try Mac("Ben", folder: folder.root, support: folder.support)
        let sync = PeerSync(store: ben.store, projectID: ben.project.id,
                            selfDeviceID: ben.identity.deviceID)
        try sync.pull(root: folder.root)
        try sync.pull(root: folder.root)
        let seen = try #require(try ben.store.member(id: renamed.id))
        #expect(seen.name == "Anna-Lena")
        #expect(seen.colorHex == "#5B8C5A")
        await anna.engine.stop()
    }

    /// The other Mac adds a file and says so in its log; a while later iCloud
    /// puts the file here. This Mac already knows the file from that log, so to
    /// its watcher the arrival is a change to a known file — and nothing
    /// explained a change, only an addition, so ten minutes later a second line
    /// went in saying somebody had changed it.
    @Test("A file the other Mac added arrives here without a second line")
    func arrivalIsNotAChange() async throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        try folder.write("alt.txt", "eins\n")
        let ben = try Mac("Ben", folder: folder.root, support: folder.support)
        await ben.engine.start()

        let anna = LocalIdentity(deviceName: "Annas Mac", member: Member(name: "Anna", colorHex: "#E4572E"))
        let savedAt = Date(timeIntervalSinceNow: -3600)
        let id = Namespace.nodeID(firstSeenPath: "neu.txt")
        _ = try await DeviceLogWriter(root: folder.root, identity: anna).append([
            .member(anna.member),
            .node(NodeRecord(id: id, path: "neu.txt", isDirectory: false, firstSeenAt: savedAt)),
            .entry(EntryRecord(entry: Entry(
                projectID: UUID(), nodeID: id, authorID: anna.member.id, createdAt: savedAt,
                observedAt: savedAt, kind: .system, text: "", event: FileEvent(type: .created),
                dedupKey: DedupKey.make(nodeID: id, event: .created, at: savedAt)))),
        ])
        await ben.engine.pullPeers()

        // iCloud keeps the date the file was saved with.
        try folder.write("neu.txt", "von Anna\n")
        try FileManager.default.setAttributes([.modificationDate: savedAt],
                                              ofItemAtPath: folder.root.appending(path: "neu.txt")
                                                  .path(percentEncoded: false))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, await ben.engine.status.pendingEvents == 0 {
            try await Task.sleep(for: .milliseconds(200))
        }
        await ben.engine.stop()

        let lines = try ben.changes().filter { $0.node?.relativePath == "neu.txt" }
        #expect(lines.map(\.entry.event?.type) == [.created], "\(lines.map(\.entry))")
        #expect(lines.first?.author?.name == "Anna")
    }

    /// This Mac's app was closed while the other Mac added one file and deleted
    /// another. On the next start their log is read first, and then the folder
    /// is compared against the index — which finds both again. The comparison
    /// used to write its own line for each, beside the one the other Mac had
    /// already written: a "changed" nobody made, and every deletion twice.
    @Test("What the other Mac did while this one was closed is told once")
    func catchUpDoesNotRepeatThePeer() async throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        // Last saved days ago, as a file that gets deleted usually was: the date a
        // comparison has to go on is the file's, the other Mac's is the deletion's.
        try folder.write("alt.txt", "eins\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
                                              ofItemAtPath: folder.root.appending(path: "alt.txt")
                                                  .path(percentEncoded: false))
        let ben = try Mac("Ben", folder: folder.root, support: folder.support)
        await ben.engine.start()
        await ben.engine.stop()

        let anna = LocalIdentity(deviceName: "Annas Mac", member: Member(name: "Anna", colorHex: "#E4572E"))
        let now = Date()
        let savedAt = now.addingTimeInterval(-3600)
        let old = try #require(try ben.node("alt.txt"))
        let new = Namespace.nodeID(firstSeenPath: "neu.txt")
        func change(_ node: UUID, _ type: FileEventType, at date: Date) -> LogBody {
            .entry(EntryRecord(entry: Entry(
                projectID: UUID(), nodeID: node, authorID: anna.member.id, createdAt: date,
                observedAt: date, kind: .system, text: "", event: FileEvent(type: type),
                dedupKey: DedupKey.make(nodeID: node, event: type, at: date))))
        }
        _ = try await DeviceLogWriter(root: folder.root, identity: anna).append([
            .member(anna.member),
            .node(NodeRecord(id: new, path: "neu.txt", isDirectory: false, firstSeenAt: savedAt)),
            change(new, .created, at: savedAt),
            change(old.id, .removed, at: now),
        ])
        try folder.write("neu.txt", "von Anna\n")
        try FileManager.default.setAttributes([.modificationDate: savedAt],
                                              ofItemAtPath: folder.root.appending(path: "neu.txt")
                                                  .path(percentEncoded: false))
        try FileManager.default.removeItem(at: folder.root.appending(path: "alt.txt"))

        // What a start does when the event history cannot be replayed: read the
        // others first, then compare the folder.
        await ben.engine.pullPeers()
        await ben.engine.rescan()

        let changes = try ben.changes()
        #expect(changes.filter { $0.node?.relativePath == "neu.txt" }.map(\.entry.event?.type) == [.created],
                "\(changes.map(\.entry))")
        #expect(changes.filter { $0.node?.relativePath == "alt.txt" }.map(\.author?.name) == ["Anna"],
                "\(changes.map(\.entry))")
        #expect(ben.changesWritten(in: folder).isEmpty, "and nothing of Ben's own went into his log")
    }

    /// A folder dragged to the Trash is one event: the folder left. Nothing is
    /// said about the files inside it, and they used to stay in the index as
    /// present — found by search, listed under tasks, opening nothing.
    @Test("A folder that goes takes the files inside it along")
    func trashedFolderTakesItsFiles() async throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        try folder.write("Entwurf/plakat.txt", "x\n")
        try folder.write("Entwurf/Varianten/b.txt", "y\n")
        try folder.write("bleibt.txt", "z\n")

        let anna = try Mac("Anna", folder: folder.root, support: folder.support)
        await anna.engine.start()
        let trash = folder.support.appending(path: "Trash-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: folder.root.appending(path: "Entwurf"), to: trash)
        defer { try? FileManager.default.removeItem(at: trash) }

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, try anna.node("Entwurf")?.state != .deleted {
            try await Task.sleep(for: .milliseconds(200))
        }
        await anna.engine.stop()

        #expect(try anna.node("Entwurf")?.state == .deleted)
        #expect(try anna.node("Entwurf/plakat.txt")?.state == .deleted)
        #expect(try anna.node("Entwurf/Varianten")?.state == .deleted)
        #expect(try anna.node("Entwurf/Varianten/b.txt")?.state == .deleted)
        #expect(try anna.node("bleibt.txt")?.state == .present)
        #expect(try anna.store.search("plakat", viewer: anna.identity.member.id).nodes
                    .allSatisfy { $0.state != .present },
                "search must not offer a file that went with its folder as if it were there")
    }
}
