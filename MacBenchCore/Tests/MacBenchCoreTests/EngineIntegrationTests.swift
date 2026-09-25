import Foundation
import Testing
@testable import MacBenchCore

/// Drives the real pipeline against a real folder: scan, compare, decide who did
/// it, write the log, and read that log back on a second machine. The parts are
/// unit-tested individually; this is the proof that they fit together.
@Suite("End to end", .serialized)
struct EngineIntegrationTests {

    private struct Bench {
        let root: URL
        let support: URL
        let store: Store
        let identity: LocalIdentity
        let engine: ProjectEngine
        let project: Project

        /// `sharedEditor` plays iCloud's record of who last saved a file; left
        /// out, it asks the real one, which in a temporary folder says nothing.
        init(memberName: String = "Anna",
             sharedEditor: (@Sendable (URL) -> SharedEditor)? = nil) throws {
            // Canonical, not merely "resolved": URL.resolvingSymlinksInPath strips a
            // leading /private, so the temp directory keeps pointing at the /var
            // symlink and the scanner takes a different branch than it does on a
            // real folder under /Users. Bugs then hide in the branch the app uses.
            root = Bench.canonical(URL(fileURLWithPath: NSTemporaryDirectory()))
                .appending(path: "macbench-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
            // Outside the watched folder, exactly as in the app: MacBench must
            // never end up reporting its own working files as somebody's changes.
            support = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "macbench-support-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            store = try Store()
            identity = LocalIdentity(deviceName: "\(memberName)s Mac",
                                     member: Member(name: memberName, colorHex: "#E4572E"))
            try store.upsert(member: identity.member)
            try store.ensureBuiltInCategories()
            project = Project(name: "Kunde A")
            try store.addProject(project, rootPath: root.path(percentEncoded: false), bookmark: nil)
            engine = try ProjectEngine(projectID: project.id, root: root, store: store,
                                       identity: identity, supportDirectory: support,
                                       sharedEditor: sharedEditor ?? { ICloudInspector().sharedEditor(of: $0) })
        }

        /// A second project on the same Mac: same store, same person, its own folder.
        static func sharing(_ other: Bench, folder: String) throws -> Bench {
            try Bench(store: other.store, identity: other.identity, support: other.support,
                      root: other.root.deletingLastPathComponent()
                          .appending(path: folder, directoryHint: .isDirectory),
                      name: folder)
        }

        private init(store: Store, identity: LocalIdentity, support: URL,
                     root: URL, name: String) throws {
            self.root = root
            self.support = support
            self.store = store
            self.identity = identity
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            project = Project(name: name)
            try store.addProject(project, rootPath: root.path(percentEncoded: false), bookmark: nil)
            engine = try ProjectEngine(projectID: project.id, root: root, store: store,
                                       identity: identity, supportDirectory: support)
        }

        static func canonical(_ url: URL) -> URL {
            let path = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
            return URL(fileURLWithPath: path ?? url.path(percentEncoded: false), isDirectory: true)
        }

        func write(_ relativePath: String, _ contents: String) throws {
            let url = root.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func remove(_ relativePath: String) throws {
            try FileManager.default.removeItem(at: root.appending(path: relativePath))
        }

        func timeline() throws -> [TimelineItem] {
            var filter = TimelineFilter()
            filter.limit = 500
            return try store.timeline(scope: .project(project.id), filter: filter,
                                      viewer: identity.member.id)
        }

        /// Waits for something the watcher is supposed to notice. FSEvents has its
        /// own latency and no completion to await, so the choice is between a fixed
        /// sleep and polling; polling keeps the suite fast when it passes and still
        /// fails within a few seconds when it does not.
        func waitFor(_ condition: () async throws -> Bool, seconds: Double = 20) async rethrows -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if try await condition() { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return try await condition()
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// The one thing that cannot be seen from inside the app: a project that is
    /// indexed, looks live, says nothing is wrong, and is not being watched at all.
    /// The first-ever run of a project used to take exactly that branch.
    /// A log that could not be written for a minute used to say so until the
    /// app was restarted — and what failed to go into it was gone for good.
    @Test("What could not be written waits, keeps its time, and goes first once it can")
    func unwrittenRecordsWait() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        _ = try await bench.engine.post(text: "eins")
        #expect(await bench.engine.status.problems.isEmpty)

        let segment = LogLayout.deviceDirectory(in: bench.root, device: bench.identity.deviceID)
            .appending(path: LogLayout.segmentName(1)).path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: segment)
        let failedAt = Date()
        _ = try await bench.engine.post(text: "zwei")
        #expect(await bench.engine.status.problems[.log] != nil)
        #expect(await bench.engine.status.unwrittenRecords == 1)
        #expect(try bench.timeline().contains { $0.entry.text == "zwei" },
                "kept here, not handed back to be sent twice")

        // The app quits before the folder is writable again.
        await bench.engine.stop()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: segment)
        try await Task.sleep(for: .milliseconds(20))
        let relaunched = try ProjectEngine(projectID: bench.project.id, root: bench.root,
                                           store: bench.store, identity: bench.identity,
                                           supportDirectory: bench.support)
        _ = try await relaunched.post(text: "drei")
        #expect(await relaunched.status.problems[.log] == nil)
        #expect(await relaunched.status.unwrittenRecords == 0)

        let peer = try #require(DeviceLogReader.peers(in: bench.root).first)
        let result = DeviceLogReader.read(peer: peer, after: 0)
        #expect(result.isComplete)
        let texts: [String] = result.records.compactMap {
            if case .entry(let entry) = $0.body, entry.kind == .message { entry.text } else { nil }
        }
        #expect(texts == ["eins", "zwei", "drei"])
        let zwei = try #require(result.records.first {
            if case .entry(let entry) = $0.body { entry.text == "zwei" } else { false }
        })
        #expect(zwei.writtenAt <= failedAt.addingTimeInterval(0.01), "the time it happened, not the time it was written")
    }

    @Test("A folder is watched from the first run, not the second")
    func watchesFromTheFirstRun() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        try bench.write("Layout/plakat.txt", "eins\n")

        await bench.engine.start()
        try bench.write("Layout/entwurf.txt", "frisch\n")

        let noticed = try await bench.waitFor {
            try bench.store.node(projectID: bench.project.id,
                                 relativePath: "Layout/entwurf.txt") != nil
        }
        #expect(noticed, "a file saved during the first session must be seen live")
        await bench.engine.stop()
    }

    @Test("The first look is silent: files that were always there are not news")
    func initialIndexIsSilent() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        try bench.write("Layout/plakat.txt", "eins\nzwei\n")
        try bench.write("Layout/.DS_Store", "junk")
        try bench.write("Video/CacheClip/blob.dat", "cache")

        await bench.engine.start()
        defer { Task { await bench.engine.stop() } }

        let opening = try bench.timeline()
        #expect(opening.count == 1, "an existing folder must not produce a wall of entries")
        #expect(opening.first?.entry.notice == .joined,
                "the one thing it does say is who just joined")
        let indexed = try bench.store.node(projectID: bench.project.id,
                                           relativePath: "Layout/plakat.txt")
        #expect(indexed != nil, "…but it must be indexed")
        #expect(try bench.store.node(projectID: bench.project.id,
                                     relativePath: "Video/CacheClip/blob.dat") == nil,
                "cache folders are never indexed at all")
    }

    @Test("A folder lists the files inside it")
    func folderListsItsFiles() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        try bench.write("Layout/plakat.afdesign", "x")
        try bench.write("Layout/entwurf.afdesign", "y")
        try bench.write("Layout/Varianten/b.afdesign", "z")
        try bench.write("angebot.txt", "top level")
        await bench.engine.start()
        defer { Task { await bench.engine.stop() } }

        let root = try #require(try bench.store.files(projectID: bench.project.id,
                                                      parentPath: "",
                                                      viewer: bench.identity.member.id))
        #expect(root.map(\.node.name) == ["angebot.txt"])

        let folder = try #require(try bench.store.node(projectID: bench.project.id,
                                                       relativePath: "Layout"))
        #expect(!folder.relativePath.hasSuffix("/"), "a folder path must have one spelling only")
        let inside = try bench.store.files(projectID: bench.project.id,
                                           parentPath: folder.relativePath,
                                           viewer: bench.identity.member.id)
        #expect(inside.map(\.node.name) == ["entwurf.afdesign", "plakat.afdesign"],
                "the folder must find the files that sit directly in it")

        let subfolders = try bench.store.folders(projectID: bench.project.id,
                                                 parentPath: folder.relativePath)
        #expect(subfolders.map(\.name) == ["Varianten"])
    }

    @Test("Changes made while the app was closed are found and attributed")
    func catchUpFindsChanges() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        try bench.write("Layout/plakat.txt", "eins\nzwei\n")
        try bench.write("Text/angebot.txt", "alt\n")
        await bench.engine.start()

        try bench.write("Layout/plakat.txt", "eins\nzwei\ndrei\nvier\n")
        try bench.write("Text/neu.txt", "frisch\n")
        try bench.remove("Text/angebot.txt")
        await bench.engine.rescan()

        // Everything about a file. The stream also holds the notice that somebody
        // joined, which is not a change and has no event of its own.
        let timeline = try bench.timeline().filter { $0.entry.event != nil }
        let kinds = timeline.compactMap { $0.entry.event?.type }
        #expect(kinds.contains(.modified))
        #expect(kinds.contains(.created))
        #expect(kinds.contains(.removed))
        #expect(timeline.allSatisfy { $0.entry.event?.backfilled == true },
                "reconstructed entries must say so, because their timing is approximate")
        #expect(timeline.allSatisfy { $0.author?.name == "Anna" })

        let modified = timeline.first { $0.entry.event?.type == .modified }
        #expect(modified?.entry.event?.linesAdded == 2, "two lines were added to a text file")
        #expect(modified?.entry.event?.linesRemoved == 0)
        await bench.engine.stop()
    }

    /// The usual day: the work is done while neither app is running, so nobody saw
    /// who did what, and working out who was awake leaves two candidates. iCloud
    /// still knows who last saved each file in a shared folder.
    @Test("A change nobody watched goes to whoever iCloud says saved it")
    func iCloudNamesTheAuthor() async throws {
        let bench = try Bench(memberName: "Anna") { url in
            guard url.lastPathComponent.hasPrefix("ben") else { return .currentUser }
            var name = PersonNameComponents()
            name.givenName = "Benjamin"
            name.familyName = "Berger"
            return .named(name)
        }
        defer { bench.cleanUp() }
        // Ben's Mac, known to the folder by its manifest, asleep throughout.
        let ben = LocalIdentity(deviceName: "Bens Mac",
                                member: Member(name: "Ben", colorHex: "#2E86AB"))
        _ = try await DeviceLogWriter(root: bench.root, identity: ben).append([.member(ben.member)])
        try bench.write("Layout/plakat.txt", "eins\n")
        try bench.write("Layout/alt.txt", "weg\n")
        await bench.engine.start()

        try bench.write("Layout/ben-entwurf.txt", "von Ben\n")
        try bench.write("Layout/plakat.txt", "eins\nzwei\n")
        try bench.remove("Layout/alt.txt")
        await bench.engine.rescan()

        let changes = try bench.timeline().filter { $0.entry.event != nil }
        func author(of name: String) -> String? {
            changes.first { $0.node?.name == name }.map { $0.author?.name ?? "nobody" }
        }
        #expect(author(of: "ben-entwurf.txt") == "Ben", "iCloud named him")
        #expect(author(of: "plakat.txt") == "Anna", "iCloud named nobody, which means the person here")
        #expect(author(of: "alt.txt") == "nobody",
                "a deleted file cannot be asked, and two people could have deleted it")
        await bench.engine.stop()
    }

    @Test("A file that moves keeps its conversation")
    func movedFileKeepsHistory() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        try bench.write("Entwurf/plakat.txt", "x\n")
        await bench.engine.start()

        let node = try #require(try bench.store.node(projectID: bench.project.id,
                                                     relativePath: "Entwurf/plakat.txt"))
        _ = try await bench.engine.post(text: "Bitte den Rand größer", nodeID: node.id)

        try FileManager.default.createDirectory(at: bench.root.appending(path: "Final"),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bench.root.appending(path: "Entwurf/plakat.txt"),
                                         to: bench.root.appending(path: "Final/plakat.txt"))
        await bench.engine.rescan()

        let moved = try #require(try bench.store.node(id: node.id))
        #expect(moved.relativePath == "Final/plakat.txt")
        let conversation = try bench.store.timeline(scope: .file(node.id), viewer: bench.identity.member.id)
        #expect(conversation.contains { $0.entry.text == "Bitte den Rand größer" },
                "the note must travel with the file, not stay with the old path")
        await bench.engine.stop()
    }

    @Test("What one machine records, the other reads back with the right name")
    func logTravelsToASecondMachine() async throws {
        let bench = try Bench(memberName: "Anna")
        defer { bench.cleanUp() }
        try bench.write("Layout/plakat.txt", "eins\n")
        await bench.engine.start()
        try bench.write("Layout/plakat.txt", "eins\nzwei\n")
        _ = try await bench.engine.post(text: "Freigabe holen", isTask: true)
        await bench.engine.rescan()
        await bench.engine.stop()

        // A second Mac, sharing the folder, that has never seen any of this.
        let other = try Store()
        let ben = Member(name: "Ben", colorHex: "#2E86AB")
        try other.upsert(member: ben)
        let mirrored = Project(name: "Kunde A")
        try other.addProject(mirrored, rootPath: bench.root.path(percentEncoded: false), bookmark: nil)
        let sync = PeerSync(store: other, projectID: mirrored.id, selfDeviceID: UUID())
        let report = try sync.pull(root: bench.root)

        #expect(report.isHealthy, "\(report.incompletePeers)")
        let timeline = try other.timeline(scope: .project(mirrored.id), viewer: ben.id)
        #expect(timeline.contains { $0.entry.text == "Freigabe holen" && $0.entry.isOpenTask })
        #expect(timeline.contains { $0.entry.event?.type == .modified })
        #expect(timeline.allSatisfy { $0.author?.name == "Anna" },
                "the other machine must not put its own name on somebody else's work")
        #expect(timeline.allSatisfy { $0.isUnread }, "and all of it is new to Ben")
    }

    /// The stream has to be able to answer "since when is she in this?", which is
    /// a question about the folder rather than about any file in it.
    @Test("The other machine learns who joined, and nothing else about a full folder")
    func joiningTravels() async throws {
        let bench = try Bench(memberName: "Anna")
        defer { bench.cleanUp() }
        try bench.write("Layout/plakat.txt", "eins\n")
        try bench.write("Text/angebot.txt", "alt\n")
        await bench.engine.start()
        await bench.engine.stop()

        let other = try Store()
        let ben = Member(name: "Ben", colorHex: "#2E86AB")
        try other.upsert(member: ben)
        let mirrored = Project(name: "Kunde A")
        try other.addProject(mirrored, rootPath: bench.root.path(percentEncoded: false), bookmark: nil)
        let sync = PeerSync(store: other, projectID: mirrored.id, selfDeviceID: UUID())
        #expect(try sync.pull(root: bench.root).isHealthy)

        let timeline = try other.timeline(scope: .project(mirrored.id), viewer: ben.id)
        let joined = try #require(timeline.first { $0.entry.notice == .joined })
        #expect(joined.author?.name == "Anna")
        #expect(joined.isUnread, "it is news to Ben")
        #expect(timeline.allSatisfy { $0.entry.event == nil },
                "the two files that were already there are still not news")
    }

    /// Versioning by renaming is the everyday move: `plakat.afdesign` becomes
    /// `plakat_v1.afdesign` and a fresh one is exported under the old name. Both
    /// files derive the same id from that path, and handing it out twice does not
    /// produce a duplicate — it drags the first file's row, and its whole
    /// conversation, onto the second.
    @Test("A recycled file name does not inherit the old file's history")
    func recycledNameKeepsItsOwnIdentity() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        try bench.write("plakat.txt", "eins\n")
        await bench.engine.start()

        let original = try #require(try bench.store.node(projectID: bench.project.id,
                                                          relativePath: "plakat.txt"))
        _ = try await bench.engine.post(text: "Rand vergrößern", nodeID: original.id)

        try FileManager.default.moveItem(at: bench.root.appending(path: "plakat.txt"),
                                         to: bench.root.appending(path: "plakat_v1.txt"))
        await bench.engine.rescan()
        #expect(try bench.store.node(id: original.id)?.relativePath == "plakat_v1.txt")

        try bench.write("plakat.txt", "ganz neu\n")
        await bench.engine.rescan()

        let renamed = try bench.store.node(projectID: bench.project.id, relativePath: "plakat_v1.txt")
        let fresh = try #require(try bench.store.node(projectID: bench.project.id,
                                                       relativePath: "plakat.txt"))
        #expect(renamed?.id == original.id, "the renamed file must still be in the index, unchanged")
        #expect(fresh.id != original.id, "and the new file must be a different file")

        let conversation = try bench.store.timeline(scope: .file(original.id),
                                                    viewer: bench.identity.member.id)
        #expect(conversation.contains { $0.entry.text == "Rand vergrößern" },
                "the note stays with the file it was written about")
        let onTheNewFile = try bench.store.timeline(scope: .file(fresh.id),
                                                    viewer: bench.identity.member.id)
        #expect(!onTheNewFile.contains { $0.entry.text == "Rand vergrößern" },
                "and does not follow the name onto an unrelated file")
        await bench.engine.stop()
    }

    /// The change is seen, its twenty-minute window is still open, and the app is
    /// quit. Losing the window is survivable; what is not is the index having
    /// already recorded that version of the file, because then the next launch's
    /// comparison finds nothing to report and the change is gone for good.
    @Test("A change that is still being gathered is not written off as indexed")
    func pendingChangeStaysFindableAfterAQuit() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        try bench.write("plakat.txt", "eins\n")
        await bench.engine.start()

        try bench.write("plakat.txt", "eins\nzwei\ndrei\n")
        let seen = try await bench.waitFor { await bench.engine.status.pendingEvents > 0 }
        #expect(seen, "precondition: the change was noticed and is being gathered")

        // ⌘Q lands here on a good day. On a crash it does not, which is why the
        // index must not have moved on ahead of the entry.
        await bench.engine.stop()
        #expect(try bench.timeline().contains { $0.entry.event?.type == .modified },
                "a clean quit flushes what is still open")

        // And the same again without the clean quit. What has to hold after a kill
        // is that the index still describes the version it last accounted for —
        // deliberately not which recovery route the next launch takes. That
        // depends on whether the event cursor happened to be written, which in
        // turn depends on how the filesystem grouped its notifications, and both
        // routes are correct.
        let rough = try Bench()
        defer { rough.cleanUp() }
        try rough.write("plakat.txt", "eins\n")
        await rough.engine.start()
        try rough.write("plakat.txt", "eins\nzwei\ndrei\n")
        _ = try await rough.waitFor { await rough.engine.status.pendingEvents > 0 }

        let indexed = try #require(try rough.store.node(projectID: rough.project.id,
                                                         relativePath: "plakat.txt"))
        #expect(indexed.fileSize == 5,
                "the index still describes the version whose change is on record")

        // So comparing the folder against it finds the change again.
        let relaunched = try ProjectEngine(projectID: rough.project.id, root: rough.root,
                                           store: rough.store, identity: rough.identity,
                                           supportDirectory: rough.support)
        await relaunched.rescan()
        #expect(try rough.timeline().contains { $0.entry.event?.type == .modified },
                "and a kill is recovered by the next comparison")
        await relaunched.stop()
        await rough.engine.stop()
    }

    /// Node ids are derived from the *relative* path so that two machines agree on
    /// them without asking each other. Every client folder has a Briefing.pdf, so
    /// two projects derive the same id — and the second one used to take over the
    /// first one's row and disappear from the index completely.
    @Test("Two clients can both have a Briefing.pdf")
    func samePathInTwoProjects() async throws {
        let meier = try Bench(memberName: "Anna")
        defer { meier.cleanUp() }
        let schmidt = try Bench.sharing(meier, folder: "Kunde Schmidt")
        defer { schmidt.cleanUp() }
        try meier.write("Briefing.pdf", "Meier\n")
        try schmidt.write("Briefing.pdf", "Schmidt\n")
        await meier.engine.start()
        await schmidt.engine.start()

        let first = try #require(try meier.store.node(projectID: meier.project.id,
                                                       relativePath: "Briefing.pdf"))
        let second = try #require(try schmidt.store.node(projectID: schmidt.project.id,
                                                          relativePath: "Briefing.pdf"))
        #expect(first.id != second.id, "two files, two identities")
        #expect(try meier.store.files(projectID: schmidt.project.id, parentPath: "",
                                      viewer: meier.identity.member.id).count == 1,
                "the second client's folder is not empty")

        // Now the harder direction: a Mac that only has Schmidt writes the
        // unsalted id into Schmidt's log, and this Mac — which has both — reads it.
        _ = try await schmidt.engine.post(text: "Briefing durchgehen", nodeID: second.id)
        await meier.engine.stop()
        await schmidt.engine.stop()

        let other = try Store()
        let ben = Member(name: "Ben", colorHex: "#2E86AB")
        try other.upsert(member: ben)
        let onlySchmidt = Project(name: "Kunde Schmidt")
        try other.addProject(onlySchmidt, rootPath: schmidt.root.path(percentEncoded: false),
                             bookmark: nil)
        let sync = PeerSync(store: other, projectID: onlySchmidt.id, selfDeviceID: UUID())
        #expect(try sync.pull(root: schmidt.root).isHealthy)
        let seen = try other.timeline(scope: .project(onlySchmidt.id), viewer: ben.id)
        #expect(seen.contains { $0.entry.text == "Briefing durchgehen" })
        #expect(seen.first { $0.entry.text == "Briefing durchgehen" }?.node?.relativePath
                == "Briefing.pdf", "and it is about a file, not a stub")
    }

    /// Moving a folder moves everything under it. The rename record carries one
    /// node, so the other Mac has to know it is a folder to move its contents with
    /// it — otherwise the folder arrives at the new path and its files stay behind
    /// at the old one, where nothing points at them any more.
    @Test("A folder that moves takes its contents with it on the other Mac")
    func renamedFolderMovesItsContents() async throws {
        let bench = try Bench(memberName: "Anna")
        defer { bench.cleanUp() }
        try bench.write("Entwurf/plakat.txt", "x\n")
        try bench.write("Entwurf/beileger.txt", "y\n")
        await bench.engine.start()

        try FileManager.default.moveItem(at: bench.root.appending(path: "Entwurf"),
                                         to: bench.root.appending(path: "Final"))
        await bench.engine.rescan()
        await bench.engine.stop()

        let other = try Store()
        let ben = Member(name: "Ben", colorHex: "#2E86AB")
        try other.upsert(member: ben)
        let mirrored = Project(name: "Kunde A")
        try other.addProject(mirrored, rootPath: bench.root.path(percentEncoded: false), bookmark: nil)
        let sync = PeerSync(store: other, projectID: mirrored.id, selfDeviceID: UUID())
        #expect(try sync.pull(root: bench.root).isHealthy)

        let inside = try other.files(projectID: mirrored.id, parentPath: "Final", viewer: ben.id)
        #expect(inside.map(\.node.name).sorted() == ["beileger.txt", "plakat.txt"],
                "the files are in the folder's new place")
        #expect(try other.files(projectID: mirrored.id, parentPath: "Entwurf",
                                viewer: ben.id).isEmpty,
                "and not left behind at the old one")
    }

    @Test("Reading the same folder twice does not double anything")
    func repeatedStartsAreIdempotent() async throws {
        let bench = try Bench()
        defer { bench.cleanUp() }
        try bench.write("a.txt", "eins\n")
        await bench.engine.start()
        try bench.write("a.txt", "eins\nzwei\n")
        await bench.engine.rescan()
        let first = try bench.timeline().count
        await bench.engine.rescan()
        await bench.engine.rescan()
        #expect(try bench.timeline().count == first)
        await bench.engine.stop()
    }
}
