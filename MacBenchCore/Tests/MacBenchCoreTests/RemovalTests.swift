import Foundation
import Testing
@testable import MacBenchCore

/// A vanished file leaves nothing to inspect, so sync removing it and somebody
/// deleting it look the same. These are the cases where that used to put this
/// Mac's name on somebody else's work.
@Suite("Who deleted or moved it", .serialized)
struct RemovalAttributionTests {

    private struct Setup {
        let root: URL
        let store: Store
        let tom = LocalIdentity(deviceName: "Toms Mac", member: Member(name: "Tom", colorHex: "#8367C7"))
        let mara = LocalIdentity(deviceName: "Maras MacBook", member: Member(name: "Mara", colorHex: "#2E86AB"))
        let project = Project(name: "Kunde A")
        let engine: ProjectEngine

        init() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
            let path = (try? base.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
            root = URL(fileURLWithPath: path ?? base.path, isDirectory: true)
                .appending(path: "macbench-rm-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try Store()
            try store.upsert(member: tom.member)
            try store.addProject(project, rootPath: root.path(percentEncoded: false), bookmark: nil)
            engine = try ProjectEngine(projectID: project.id, root: root, store: store, identity: tom,
                                       supportDirectory: root.deletingLastPathComponent()
                                           .appending(path: "support-\(UUID().uuidString)"))
        }

        func write(_ relative: String) throws {
            try "x".write(to: root.appending(path: relative), atomically: true, encoding: .utf8)
        }

        /// Deletes the file and waits until the watcher has noticed.
        func deleteAndWait(_ relative: String) async throws {
            try FileManager.default.removeItem(at: root.appending(path: relative))
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if try store.node(projectID: project.id, relativePath: relative)?.state == .deleted { return }
                try await Task.sleep(for: .milliseconds(200))
            }
            Issue.record("the watcher never saw \(relative) go")
        }

        func removals() throws -> [TimelineItem] {
            try store.timeline(scope: .project(project.id), viewer: tom.member.id)
                .filter { $0.entry.event?.type == .removed }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Deleting a file with nobody else around is mine")
    func aloneItIsMine() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        try setup.write("brief.txt")
        await setup.engine.start()
        try await setup.deleteAndWait("brief.txt")
        await setup.engine.stop()

        #expect(try setup.removals().map { $0.author?.name } == ["Tom"])
    }

    @Test("If the other Mac was running and said nothing, it was me")
    func awakeAndSilentPeerIsRuledOut() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let writer = try DeviceLogWriter(root: setup.root, identity: setup.mara)
        try await writer.recordHeartbeat(now: Date())
        try setup.write("brief.txt")
        await setup.engine.start()
        try await setup.deleteAndWait("brief.txt")
        try await writer.recordHeartbeat(now: Date())
        await setup.engine.stop()

        #expect(try setup.removals().map { $0.author?.name } == ["Tom"])
    }

    @Test("If the other Mac was not running, nobody can tell, and it says so")
    func sleepingPeerLeavesItOpen() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let writer = try DeviceLogWriter(root: setup.root, identity: setup.mara)
        try await writer.recordHeartbeat(now: Date(timeIntervalSinceNow: -86_400))
        try setup.write("brief.txt")
        await setup.engine.start()
        try await setup.deleteAndWait("brief.txt")
        await setup.engine.stop()

        let removals = try setup.removals()
        #expect(removals.count == 1)
        #expect(removals.first?.entry.authorID == nil,
                "a deletion that may have arrived through sync must not carry this Mac's name")
    }

    @Test("When the other Mac says it deleted the file, that is the only line")
    func peerExplainsIt() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        try setup.write("brief.txt")
        await setup.engine.start()
        let node = try #require(try setup.store.node(projectID: setup.project.id, relativePath: "brief.txt"))
        try await setup.deleteAndWait("brief.txt")

        // Mara's log arrives: she deleted it, a little earlier than it vanished here.
        let writer = try DeviceLogWriter(root: setup.root, identity: setup.mara)
        let deletedAt = Date(timeIntervalSinceNow: -120)
        _ = try await writer.append([.entry(EntryRecord(entry: Entry(
            projectID: setup.project.id, nodeID: node.id, authorID: setup.mara.member.id,
            createdAt: deletedAt, observedAt: deletedAt, kind: .system, text: "",
            event: FileEvent(type: .removed),
            dedupKey: DedupKey.make(nodeID: node.id, event: .removed, at: deletedAt.addingTimeInterval(-3600)))))])
        await setup.engine.pullPeers()
        await setup.engine.stop()

        #expect(try setup.removals().map { $0.author?.name } == ["Mara"])
    }

    // MARK: Moves — sync carries out the other Mac's move here exactly as one made here.

    private func moveAndWait(_ setup: Setup, _ from: String, to: String) async throws {
        try FileManager.default.moveItem(at: setup.root.appending(path: from),
                                         to: setup.root.appending(path: to))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if try setup.store.node(projectID: setup.project.id, relativePath: to)?.state == .present,
               try setup.store.node(projectID: setup.project.id, relativePath: from) == nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("the watcher never saw \(from) move")
    }

    private func moves(_ setup: Setup) throws -> [TimelineItem] {
        try setup.store.timeline(scope: .project(setup.project.id), viewer: setup.tom.member.id)
            .filter { $0.entry.event?.type == .moved || $0.entry.event?.type == .renamed }
    }

    @Test("Moving a folder with nobody else around is mine")
    func aloneTheMoveIsMine() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let files = FileManager.default
        try files.createDirectory(at: setup.root.appending(path: "Entwuerfe"), withIntermediateDirectories: true)
        try files.createDirectory(at: setup.root.appending(path: "Loewenmut"), withIntermediateDirectories: true)
        try setup.write("Entwuerfe/skizze.txt")
        await setup.engine.start()
        try await moveAndWait(setup, "Entwuerfe", to: "Loewenmut/Entwuerfe")
        await setup.engine.stop()

        #expect(try moves(setup).map { $0.author?.name } == ["Tom"])
    }

    @Test("A move while the other Mac was not running is nobody's for certain")
    func sleepingPeerLeavesTheMoveOpen() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let writer = try DeviceLogWriter(root: setup.root, identity: setup.mara)
        try await writer.recordHeartbeat(now: Date(timeIntervalSinceNow: -86_400))
        let files = FileManager.default
        try files.createDirectory(at: setup.root.appending(path: "Entwuerfe"), withIntermediateDirectories: true)
        try files.createDirectory(at: setup.root.appending(path: "Loewenmut"), withIntermediateDirectories: true)
        try setup.write("Entwuerfe/skizze.txt")
        await setup.engine.start()
        try await moveAndWait(setup, "Entwuerfe", to: "Loewenmut/Entwuerfe")
        await setup.engine.stop()

        let moves = try moves(setup)
        #expect(moves.count == 1)
        #expect(moves.first?.entry.authorID == nil,
                "a move sync may have carried out must not carry this Mac's name")
    }

    @Test("When the other Mac says it moved the file, that is the only line")
    func peerExplainsTheMove() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        try FileManager.default.createDirectory(at: setup.root.appending(path: "Final"),
                                                withIntermediateDirectories: true)
        try setup.write("brief.txt")
        await setup.engine.start()
        let node = try #require(try setup.store.node(projectID: setup.project.id, relativePath: "brief.txt"))
        try await moveAndWait(setup, "brief.txt", to: "Final/brief.txt")

        let writer = try DeviceLogWriter(root: setup.root, identity: setup.mara)
        let movedAt = Date(timeIntervalSinceNow: -30)
        _ = try await writer.append([.entry(EntryRecord(entry: Entry(
            projectID: setup.project.id, nodeID: node.id, authorID: setup.mara.member.id,
            createdAt: movedAt, observedAt: movedAt, kind: .system, text: "",
            event: FileEvent(type: .moved, fromPath: "brief.txt"),
            dedupKey: DedupKey.make(nodeID: node.id, event: .moved, at: movedAt.addingTimeInterval(-3600)))))])
        await setup.engine.pullPeers()
        await setup.engine.stop()

        #expect(try moves(setup).map { $0.author?.name } == ["Mara"])
    }

    // MARK: Opening is not changing

    @Test("Touching a file without changing it is not a change")
    func metadataIsNotAChange() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        try setup.write("brief.txt")
        await setup.engine.start()
        // What opening a document does: the system notes when it was last used.
        let url = setup.root.appending(path: "brief.txt")
        let value = Data(repeating: 1, count: 16)
        _ = value.withUnsafeBytes { bytes in
            setxattr(url.path, "com.apple.lastuseddate#PS", bytes.baseAddress, bytes.count, 0, 0)
        }
        try await Task.sleep(for: .seconds(3))
        await setup.engine.stop()

        let changes = try setup.store.timeline(scope: .project(setup.project.id), viewer: setup.tom.member.id)
            .filter { $0.entry.event != nil }
        #expect(changes.isEmpty, "\(changes.map { $0.entry.event?.type as Any })")
    }

    @Test("A file only the other Mac has is not deleted here because it is missing")
    func missingPeerFileIsNotADeletion() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        try setup.write("brief.txt")
        await setup.engine.start()
        await setup.engine.stop()

        // Mara registers a file whose bytes have not reached this Mac yet.
        let writer = try DeviceLogWriter(root: setup.root, identity: setup.mara)
        _ = try await writer.append([.node(NodeRecord(id: UUID(), path: "Illustration.png",
                                                      isDirectory: false, firstSeenAt: Date()))])
        await setup.engine.pullPeers()
        await setup.engine.rescan()

        let removals = try setup.removals()
        #expect(removals.isEmpty, "\(removals.map(\.entry))")
        #expect(try setup.store.node(projectID: setup.project.id,
                                     relativePath: "Illustration.png")?.state == .present,
                "it still exists — just not here yet")
    }
}
