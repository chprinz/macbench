import Foundation
import Testing
@testable import MacBenchCore

@Suite("Document packages")
struct DocumentPackageTests {

    @Test("A package is found from anywhere inside it")
    func findsTheRoot() {
        #expect(DocumentPackage.root(of: "Konzept/Struktur.pages/Data/bild.png") == "Konzept/Struktur.pages")
        #expect(DocumentPackage.root(of: "Konzept/Struktur.pages") == "Konzept/Struktur.pages")
        #expect(DocumentPackage.root(of: "Konzept/Struktur.PAGES/Index.zip") == "Konzept/Struktur.PAGES")
        #expect(DocumentPackage.root(of: "Konzept/bild.png") == nil)
        // A folder merely named like one does not count unless it ends that way.
        #expect(DocumentPackage.root(of: "pages/bild.png") == nil)
    }

    @Test("Only what is strictly inside is interior")
    func interior() {
        #expect(DocumentPackage.isInside("A.key/Data/x.jpg"))
        #expect(!DocumentPackage.isInside("A.key"))
        #expect(!DocumentPackage.isInside("A/x.jpg"))
    }

    @Test("A package's date is the newest thing in it")
    func stamp() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "stamp-\(UUID().uuidString).pages", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appending(path: "Data"),
                                                withIntermediateDirectories: true)
        let old = url.appending(path: "Data/bild.png")
        try Data(repeating: 1, count: 100).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400 * 3)],
                                              ofItemAtPath: old.path)
        try Data(repeating: 2, count: 50).write(to: url.appending(path: "Index.zip"))

        let stamp = DocumentPackage.stamp(of: url)
        #expect(stamp.size == 150)
        #expect(abs(try #require(stamp.modifiedAt).timeIntervalSinceNow) < 60,
                "an image placed days ago must not make a fresh save look old")
    }
}

@Suite("Document packages end to end", .serialized)
struct DocumentPackageEngineTests {

    private func makeRoot() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let path = (try? base.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
        let root = URL(fileURLWithPath: path ?? base.path, isDirectory: true)
            .appending(path: "macbench-pkg-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: URL, _ relative: String, _ contents: String) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("A Pages document is indexed as one file, and editing it is one change")
    func packageIsOneDocument() async throws {
        let root = try makeRoot()
        let support = root.deletingLastPathComponent().appending(path: "support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "Konzept/Struktur.pages/Index.zip", "a")
        try write(root, "Konzept/Struktur.pages/Data/bild.png", "b")

        let store = try Store()
        let identity = LocalIdentity(deviceName: "Annas Mac", member: Member(name: "Anna", colorHex: "#E4572E"))
        try store.upsert(member: identity.member)
        let project = Project(name: "Kunde A")
        try store.addProject(project, rootPath: root.path(percentEncoded: false), bookmark: nil)
        let engine = try ProjectEngine(projectID: project.id, root: root, store: store,
                                       identity: identity, supportDirectory: support)
        await engine.start()

        let package = try #require(try store.node(projectID: project.id,
                                                  relativePath: "Konzept/Struktur.pages"))
        #expect(!package.isDirectory, "the document must not be something to open like a folder")
        #expect(try store.node(projectID: project.id,
                               relativePath: "Konzept/Struktur.pages/Index.zip") == nil)

        try write(root, "Konzept/Struktur.pages/Index.zip", "changed")
        try write(root, "Konzept/Struktur.pages/preview.jpg", "new")
        try await Task.sleep(for: .seconds(3))
        await engine.stop()

        let nodes = try store.read { db in
            try String.fetchAll(db, sql: "SELECT relativePath FROM node WHERE projectID = ?",
                                arguments: [project.id])
        }
        #expect(!nodes.contains { DocumentPackage.isInside($0) },
                "nothing inside the document may become a node: \(nodes)")
        let changes = try store.timeline(scope: .project(project.id), viewer: identity.member.id)
            .filter { $0.entry.event != nil }
        #expect(changes.count == 1, "\(changes.map { $0.entry.event?.type as Any })")
        #expect(changes.first?.entry.nodeID == package.id)
        #expect(changes.first?.entry.authorID == identity.member.id)
    }

    @Test("An index from before packages were documents is folded into them")
    func foldsExistingIndex() throws {
        let store = try Store()
        let anna = Member(name: "Anna", colorHex: "#E4572E")
        try store.upsert(member: anna)
        let project = Project(name: "Kunde A")
        try store.addProject(project, rootPath: "/tmp/nowhere", bookmark: nil)
        // The start of a dedup bucket, so the three seconds of one save cannot
        // straddle two of them.
        let now = Date(timeIntervalSince1970: DedupKey.bucket * 1_491_667)

        func node(_ path: String, directory: Bool) throws -> Node {
            let node = Node(id: UUID(), projectID: project.id, relativePath: path,
                            isDirectory: directory, firstSeenAt: now, lastSeenAt: now)
            try store.upsert(node: node)
            return node
        }
        let package = try node("Struktur.pages", directory: true)
        let inner = try node("Struktur.pages/Index.zip", directory: false)
        let outside = try node("brief.txt", directory: false)

        let image = try node("Struktur.pages/Data/bild.png", directory: false)
        // One save: the index rewritten, an image renamed, an old one dropped.
        try store.merge(entry: Entry(projectID: project.id, nodeID: inner.id, authorID: nil,
                                     createdAt: now, observedAt: now, kind: .system, text: "",
                                     event: FileEvent(type: .modified), dedupKey: "a"))
        try store.merge(entry: Entry(projectID: project.id, nodeID: image.id, authorID: nil,
                                     createdAt: now.addingTimeInterval(1), observedAt: now,
                                     kind: .system, text: "",
                                     event: FileEvent(type: .renamed), dedupKey: "c"))
        try store.merge(entry: Entry(projectID: project.id, nodeID: image.id, authorID: anna.id,
                                     createdAt: now.addingTimeInterval(2), observedAt: now,
                                     kind: .system, text: "",
                                     event: FileEvent(type: .removed), dedupKey: "d"))
        let note = Entry(projectID: project.id, nodeID: inner.id, authorID: anna.id,
                         createdAt: now, observedAt: now, kind: .message, text: "Seite 2?")
        try store.merge(entry: note)
        try store.merge(entry: Entry(projectID: project.id, nodeID: outside.id, authorID: anna.id,
                                     createdAt: now, observedAt: now, kind: .system, text: "",
                                     event: FileEvent(type: .modified), dedupKey: "b"))

        #expect(try store.foldDocumentPackages(projectID: project.id) == 2)
        #expect(try store.foldDocumentPackages(projectID: project.id) == 0, "idempotent")

        #expect(try store.node(projectID: project.id, relativePath: "Struktur.pages")?.isDirectory == false)
        #expect(try store.node(projectID: project.id, relativePath: "Struktur.pages/Index.zip") == nil)
        let timeline = try store.timeline(scope: .project(project.id), viewer: anna.id)
        #expect(timeline.count == 3, "\(timeline.map { $0.entry.event?.type as Any })")
        let saves = timeline.filter { $0.entry.nodeID == package.id && $0.entry.event != nil }
        #expect(saves.count == 1, "one save of the document, not one line per file inside it")
        #expect(saves.first?.entry.event?.type == .modified,
                "a file vanishing from inside is not somebody deleting something")
        #expect(timeline.contains { $0.entry.nodeID == outside.id }, "the change outside stays")
        #expect(timeline.first { $0.entry.id == note.id }?.entry.nodeID == package.id,
                "what somebody wrote moves to the document")
    }

    @Test("A peer on an older version cannot bring the interior back")
    func peerInteriorIsIgnored() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mara = LocalIdentity(deviceName: "Maras Mac", member: Member(name: "Mara", colorHex: "#2E86AB"))
        let writer = try DeviceLogWriter(root: root, identity: mara)
        let now = Date()
        let packageID = UUID(), innerID = UUID()
        let project = Project(name: "Kunde A")
        _ = try await writer.append([
            .node(NodeRecord(id: packageID, path: "Struktur.pages", isDirectory: true, firstSeenAt: now)),
            .node(NodeRecord(id: innerID, path: "Struktur.pages/Data/bild.png", isDirectory: false,
                             firstSeenAt: now)),
            .entry(EntryRecord(entry: Entry(projectID: project.id, nodeID: innerID, authorID: nil,
                                            createdAt: now, observedAt: now, kind: .system, text: "",
                                            event: FileEvent(type: .removed), dedupKey: "x"))),
            .entry(EntryRecord(entry: Entry(projectID: project.id, nodeID: innerID,
                                            authorID: mara.member.id,
                                            createdAt: now.addingTimeInterval(3600), observedAt: now,
                                            kind: .system, text: "",
                                            event: FileEvent(type: .modified), dedupKey: "z"))),
            .entry(EntryRecord(entry: Entry(projectID: project.id, nodeID: packageID,
                                            authorID: mara.member.id, createdAt: now, observedAt: now,
                                            kind: .system, text: "",
                                            event: FileEvent(type: .created), dedupKey: "y"))),
        ])

        let store = try Store()
        let tom = Member(name: "Tom", colorHex: "#E4572E")
        try store.upsert(member: tom)
        try store.addProject(project, rootPath: root.path(percentEncoded: false), bookmark: nil)
        try PeerSync(store: store, projectID: project.id, selfDeviceID: UUID()).pull(root: root)

        #expect(try store.node(projectID: project.id, relativePath: "Struktur.pages")?.isDirectory == false)
        let timeline = try store.timeline(scope: .project(project.id), viewer: tom.id)
        #expect(timeline.map { $0.entry.event?.type } == [.created, .modified],
                "the document and its later save, and no placeholder for the image inside it")
        #expect(timeline.allSatisfy { $0.entry.nodeID != nil && $0.author?.name == "Mara" })
    }
}
