import Foundation
import Testing
@testable import MacBenchCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Authorship")
struct AuthorshipResolverTests {
    let resolver = AuthorshipResolver()

    @Test("A file iCloud just put in place is not our work")
    func materialisedFileIsIncoming() {
        var signals = FileOriginSignals()
        signals.wasJustMaterialised = true
        #expect(resolver.assessLive(signals) == .incoming)
    }

    @Test("A file still arriving is not our work")
    func downloadingIsIncoming() {
        var signals = FileOriginSignals()
        signals.isDownloading = true
        #expect(resolver.assessLive(signals) == .incoming)
    }

    @Test("A file we are uploading is our work")
    func uploadingIsLocal() {
        var signals = FileOriginSignals()
        signals.isUploading = true
        signals.contentAge = 3
        #expect(resolver.assessLive(signals) == .local)
    }

    @Test("A change dated hours ago did not happen here just now")
    func staleContentIsIncoming() {
        var signals = FileOriginSignals()
        signals.contentAge = 4 * 3600
        #expect(resolver.assessLive(signals) == .incoming)
    }

    @Test("An ordinary save is ours")
    func freshLocalSave() {
        var signals = FileOriginSignals()
        signals.contentAge = 2
        #expect(resolver.assessLive(signals) == .local)
    }

    @Test("A machine that was awake and silent rules its own user out")
    func backfillInference() {
        let me = UUID(), them = UUID()
        let awakeThen = [AwakeWindow(from: t0.addingTimeInterval(-3600), to: t0.addingTimeInterval(3600))]

        // They were watching and said nothing, so the change was not theirs.
        #expect(resolver.inferBackfill(changeAt: t0, selfMember: me, selfAwake: [],
                                       peers: [PeerAwareness(memberID: them, windows: awakeThen)])
                == .local)

        // We were watching and said nothing, so it was theirs.
        #expect(resolver.inferBackfill(changeAt: t0, selfMember: me, selfAwake: awakeThen,
                                       peers: [PeerAwareness(memberID: them, windows: [])])
                == .inferred(them))

        // Both machines were asleep: nobody can know, and the app says so.
        #expect(resolver.inferBackfill(changeAt: t0, selfMember: me, selfAwake: [],
                                       peers: [PeerAwareness(memberID: them, windows: [])])
                == .unknown)
    }

    @Test("With three people an unwitnessed change stays unattributed")
    func inferenceNeedsASingleCandidate() {
        let me = UUID()
        let verdict = AuthorshipResolver().inferBackfill(
            changeAt: t0, selfMember: me, selfAwake: [],
            peers: [PeerAwareness(memberID: UUID(), windows: []),
                    PeerAwareness(memberID: UUID(), windows: [])])
        #expect(verdict == .unknown)
    }

    private func name(_ given: String, _ family: String) -> PersonNameComponents {
        var name = PersonNameComponents()
        name.givenName = given
        name.familyName = family
        return name
    }

    @Test("An iCloud account name finds the person it belongs to")
    func iCloudNameFindsMember() {
        let mara = Member(name: "Mara", colorHex: "#000000")
        let max = Member(name: "Max", colorHex: "#000000")
        let tom = Member(name: "Tom", colorHex: "#000000")
        #expect(AuthorshipResolver.member(named: name("Mara", "Lindqvist"), among: [max, mara, tom])
                == mara.id, "the first name is what people call themselves in the app")
        #expect(AuthorshipResolver.member(named: name("Maximilian", "Weber"), among: [max, mara, tom])
                == max.id, "and sometimes the short form of it")
        #expect(AuthorshipResolver.member(named: name("Mára", "Lindqvist"), among: [mara, tom])
                == mara.id, "accents and case are not a different person")
    }

    @Test("With one other person in the project, any other name is theirs")
    func onlyOtherPersonTakesUnknownName() {
        let mara = Member(name: "M.", colorHex: "#000000")
        #expect(AuthorshipResolver.member(named: name("Mara", "Lindqvist"), among: [mara]) == mara.id)
    }

    @Test("A name that fits nobody, or two people, is not guessed at")
    func unclearNameStaysUnattributed() {
        let tom = Member(name: "Tom", colorHex: "#000000")
        let anna = Member(name: "Anna", colorHex: "#000000")
        #expect(AuthorshipResolver.member(named: name("Mara", "Lindqvist"), among: [tom, anna]) == nil)
        let max = Member(name: "Max", colorHex: "#000000")
        let maxine = Member(name: "Maxine", colorHex: "#000000")
        #expect(AuthorshipResolver.member(named: name("Max", "Weber"), among: [max, maxine])
                == max.id, "an exact first name beats a longer one it starts")
    }

    /// Seen live, a file arriving from the other Mac can still carry the last
    /// editor from before. Trusting "nobody named" then would put the name of the
    /// person here on somebody else's work.
    @Test("No name from iCloud means the person here only where it cannot be stale")
    func currentUserNeedsTrust() {
        let me = UUID()
        #expect(resolver.author(from: .currentUser, selfMember: me, others: [],
                                trustCurrentUser: false) == nil)
        #expect(resolver.author(from: .currentUser, selfMember: me, others: [],
                                trustCurrentUser: true) == me)
        #expect(resolver.author(from: .notShared, selfMember: me, others: [],
                                trustCurrentUser: true) == nil,
                "a folder that is not shared says nothing either way")
    }
}

@Suite("Two machines, one folder")
struct PeerSyncTests {

    private func makeRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "macbench-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("What one machine writes, the other reads with the right author")
    func entryTravels() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let anna = Member(name: "Anna", colorHex: "#E4572E")
        let annaIdentity = LocalIdentity(deviceName: "Annas MacBook", member: anna)
        let writer = try DeviceLogWriter(root: root, identity: annaIdentity)

        let path = "Layout/plakat.afdesign"
        let nodeID = Namespace.nodeID(firstSeenPath: path)
        let entry = Entry(projectID: UUID(), nodeID: nodeID, authorID: anna.id,
                          createdAt: t0, observedAt: t0, kind: .message,
                          text: "Titel bitte zwei Punkt größer", isTask: true)
        _ = try await writer.append([
            .member(anna),
            .node(NodeRecord(id: nodeID, path: path, isDirectory: false, firstSeenAt: t0)),
            .entry(EntryRecord(entry: entry)),
        ])

        // Ben's machine, which has never seen any of this.
        let store = try Store()
        let ben = Member(name: "Ben", colorHex: "#2E86AB")
        try store.upsert(member: ben, at: t0)
        let project = Project(id: UUID(), name: "Kunde A", addedAt: t0)
        try store.addProject(project, rootPath: root.path, bookmark: nil)

        let sync = PeerSync(store: store, projectID: project.id, selfDeviceID: UUID())
        let report = try sync.pull(root: root, now: t0)
        #expect(report.isHealthy)
        #expect(report.newEntries == 1)

        let timeline = try store.timeline(scope: .project(project.id), viewer: ben.id)
        #expect(timeline.count == 1)
        #expect(timeline[0].author?.name == "Anna")
        #expect(timeline[0].node?.relativePath == path)
        #expect(timeline[0].isUnread)
        #expect(timeline[0].entry.isOpenTask)
    }

    @Test("Reading twice does not produce the entry twice")
    func pullIsIdempotent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let anna = Member(name: "Anna", colorHex: "#E4572E")
        let writer = try DeviceLogWriter(root: root,
                                         identity: LocalIdentity(deviceName: "A", member: anna))
        let entry = Entry(projectID: UUID(), authorID: anna.id, createdAt: t0, observedAt: t0,
                          kind: .message, text: "hallo")
        _ = try await writer.append([.member(anna), .entry(EntryRecord(entry: entry))])

        let store = try Store()
        let project = Project(id: UUID(), name: "P", addedAt: t0)
        try store.addProject(project, rootPath: root.path, bookmark: nil)
        let sync = PeerSync(store: store, projectID: project.id, selfDeviceID: UUID())
        try sync.pull(root: root, now: t0)
        try sync.pull(root: root, now: t0)
        _ = try await writer.append([.entry(EntryRecord(entry: entry))])
        try sync.pull(root: root, now: t0)

        #expect(try store.timeline(scope: .project(project.id), viewer: UUID()).count == 1)
    }

    @Test("A device folder the filesystem calls hidden is still a peer")
    func hiddenDeviceFolderIsStillRead() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let anna = Member(name: "Anna", colorHex: "#E4572E")
        let identity = LocalIdentity(deviceName: "Annas MacBook", member: anna)
        let writer = try DeviceLogWriter(root: root, identity: identity)
        let entry = Entry(projectID: UUID(), authorID: anna.id, createdAt: t0, observedAt: t0,
                          kind: .message, text: "hallo")
        _ = try await writer.append([.member(anna), .entry(EntryRecord(entry: entry))])

        // The whole log lives inside `.macbench`, and iCloud Drive reports what is
        // inside a hidden folder as hidden as well. Skipping hidden items here
        // means the other machine never appears at all.
        var dir = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
        var values = URLResourceValues()
        values.isHidden = true
        try dir.setResourceValues(values)

        let store = try Store()
        let project = Project(id: UUID(), name: "P", addedAt: t0)
        try store.addProject(project, rootPath: root.path, bookmark: nil)
        let sync = PeerSync(store: store, projectID: project.id, selfDeviceID: UUID())
        let report = try sync.pull(root: root, now: t0)

        #expect(report.newEntries == 1)
        #expect(try store.members().contains { $0.name == "Anna" })
    }

    @Test("A missing segment parks the watermark instead of skipping past it")
    func gapsBlockTheWatermark() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let anna = Member(name: "Anna", colorHex: "#E4572E")
        let identity = LocalIdentity(deviceName: "A", member: anna)
        let writer = try DeviceLogWriter(root: root, identity: identity)
        let filler = String(repeating: "y", count: 900)
        for index in 0..<400 {
            _ = try await writer.append([.entry(EntryRecord(entry:
                Entry(projectID: UUID(), authorID: anna.id, createdAt: t0, observedAt: t0,
                      kind: .message, text: "\(index) \(filler)")))])
        }

        // Sync has not delivered the first segment yet.
        let dir = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
        let first = dir.appending(path: LogLayout.segmentName(1))
        try FileManager.default.removeItem(at: first)

        let store = try Store()
        let project = Project(id: UUID(), name: "P", addedAt: t0)
        try store.addProject(project, rootPath: root.path, bookmark: nil)
        let sync = PeerSync(store: store, projectID: project.id, selfDeviceID: UUID())
        let report = try sync.pull(root: root, now: t0)

        #expect(!report.isHealthy, "a hole in the log must be visible, not silent")
        let peers = try store.peers(for: project.id)
        #expect(peers.first?.appliedSequence == 0,
                "nothing may be considered done while an earlier record is missing")
        #expect(peers.first?.isBehind == true)
    }

    /// Delete the old poster, rename the new one to its name: the everyday way of
    /// replacing a file. The deleted one still holds that path in the index, and
    /// moving onto it broke the one-node-per-path rule. The rename record threw,
    /// the read stopped there, and since the watermark cannot pass a record that
    /// was not applied, nothing that Mac ever wrote afterwards arrived.
    @Test("A file renamed onto the name of a deleted one does not stop the reading")
    func renameOntoDeletedName() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let anna = Member(name: "Anna", colorHex: "#E4572E")
        let writer = try DeviceLogWriter(root: root,
                                         identity: LocalIdentity(deviceName: "A", member: anna))
        let old = Namespace.nodeID(firstSeenPath: "Poster.pdf")
        let new = Namespace.nodeID(firstSeenPath: "Poster_v2.pdf")
        let later = Entry(projectID: UUID(), nodeID: new, authorID: anna.id,
                          createdAt: t0.addingTimeInterval(120), observedAt: t0, kind: .message,
                          text: "Das ist jetzt die Fassung für den Druck")
        _ = try await writer.append([
            .member(anna),
            .node(NodeRecord(id: old, path: "Poster.pdf", isDirectory: false, firstSeenAt: t0)),
            .node(NodeRecord(id: new, path: "Poster_v2.pdf", isDirectory: false, firstSeenAt: t0)),
            .nodeState(NodeStateRecord(id: old, state: .deleted, at: t0.addingTimeInterval(60))),
            .nodeRename(NodeRenameRecord(id: new, from: "Poster_v2.pdf", to: "Poster.pdf",
                                         at: t0.addingTimeInterval(90), isDirectory: false)),
            .entry(EntryRecord(entry: later)),
        ])

        let store = try Store()
        let project = Project(id: UUID(), name: "P", addedAt: t0)
        try store.addProject(project, rootPath: root.path, bookmark: nil)
        let sync = PeerSync(store: store, projectID: project.id, selfDeviceID: UUID())
        let report = try sync.pull(root: root, now: t0)

        #expect(report.isHealthy, "\(report.incompletePeers)")
        #expect(try store.peers(for: project.id).first?.appliedSequence == 6,
                "every record was applied, so the watermark is past all of them")
        let poster = try #require(try store.node(projectID: project.id, relativePath: "Poster.pdf"))
        #expect(poster.state == .present)
        let said = try store.timeline(scope: .project(project.id), viewer: UUID())
            .first { $0.entry.text == later.text }
        #expect(said?.node?.relativePath == "Poster.pdf", "and what was said lands on the file")
    }

    /// One bad record must cost one peer, not every peer: the error used to leave
    /// `pull` altogether, so the Mac listed after a broken one was never read.
    @Test("A record that cannot be applied holds up its own Mac, and only that one")
    func brokenPeerDoesNotBlockTheOthers() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store()
        let project = Project(id: UUID(), name: "P", addedAt: t0)
        try store.addProject(project, rootPath: root.path, bookmark: nil)

        // A node this project already holds, at a path somebody else's log
        // registers under a different id: the one collision `ensureNode` does
        // not settle, because both claim to be older.
        let anna = Member(name: "Anna", colorHex: "#E4572E")
        let ben = Member(name: "Ben", colorHex: "#2E86AB")
        for member in [anna, ben] {
            let writer = try DeviceLogWriter(root: root,
                                             identity: LocalIdentity(deviceName: member.name, member: member))
            let entry = Entry(projectID: UUID(), authorID: member.id, createdAt: t0, observedAt: t0,
                              kind: .message, text: "von \(member.name)")
            _ = try await writer.append([.member(member), .entry(EntryRecord(entry: entry))])
        }
        // Make the first peer in reading order unreadable in a way that throws:
        // an entry about a node whose stub cannot be created.
        let peers = DeviceLogReader.peers(in: root)
        let first = try #require(peers.first)
        let blocker = Namespace.nodeID(firstSeenPath: "blocker.txt")
        try store.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_stub BEFORE INSERT ON node
                WHEN NEW.relativePath LIKE '?/%'
                BEGIN SELECT RAISE(ABORT, 'refused for the test'); END
                """)
        }
        let firstWriter = try DeviceLogWriter(root: root, identity: LocalIdentity(
            deviceID: first.deviceID, deviceName: first.manifest?.deviceName ?? "",
            member: try #require(first.manifest?.member)))
        _ = try await firstWriter.append([.entry(EntryRecord(entry: Entry(
            projectID: UUID(), nodeID: blocker, authorID: first.manifest?.member.id,
            createdAt: t0, observedAt: t0, kind: .message, text: "über eine Datei")))])

        let sync = PeerSync(store: store, projectID: project.id, selfDeviceID: UUID())
        let report = try sync.pull(root: root, now: t0)

        let texts = Set(try store.timeline(scope: .project(project.id), viewer: UUID()).map(\.entry.text))
        #expect(texts.contains("von Anna") && texts.contains("von Ben"),
                "both Macs were read up to where they could be")
        #expect(report.incompletePeers.contains { if case .unreadable = $0.kind { true } else { false } },
                "and the one that could not be read all the way says so")
        let stuck = try #require(try store.peers(for: project.id).first { $0.deviceID == first.deviceID })
        #expect(stuck.appliedSequence == 2, "its watermark stops before the record that failed")
    }

    @Test("Two machines that minted different ids for one file end up on the same one")
    func nodeIdentityConverges() throws {
        let store = try Store()
        let project = Project(id: UUID(), name: "P", addedAt: t0)
        try store.addProject(project, rootPath: "/tmp/p", bookmark: nil)
        let sync = PeerSync(store: store, projectID: project.id, selfDeviceID: UUID())

        // This machine indexed the file after it had already been renamed.
        let mine = Namespace.nodeID(firstSeenPath: "Layout/plakat_final.afdesign")
        try store.upsert(node: Node(id: mine, projectID: project.id,
                                    relativePath: "Layout/plakat_final.afdesign",
                                    isDirectory: false, firstSeenAt: t0, lastSeenAt: t0))
        // The other machine saw it earlier, under its original name.
        let theirs = Namespace.nodeID(firstSeenPath: "Layout/plakat.afdesign")
        try sync.ensureNode(id: theirs, path: "Layout/plakat_final.afdesign", isDirectory: false,
                            firstSeenAt: t0.addingTimeInterval(-3600), at: t0)

        #expect(try store.node(id: mine)?.id == theirs, "the older registration wins")
        #expect(try store.node(id: theirs)?.id == theirs)
    }
}

@Suite("Records that arrive out of order")
struct OutOfOrderRecordTests {

    /// A watermark parks at a gap but the records beyond it are still applied, so
    /// a rename can land before the registration of the thing being renamed. The
    /// stub put in its place has to know whether it stands for a folder: moving a
    /// folder moves everything under it, and moving a file does not.
    @Test("A folder renamed before its registration arrived still takes its contents")
    func renameBeforeRegistration() throws {
        let store = try Store()
        let project = Project(id: UUID(), name: "P", addedAt: t0)
        try store.addProject(project, rootPath: "/tmp/p", bookmark: nil)
        let sync = PeerSync(store: store, projectID: project.id, selfDeviceID: UUID())

        // The files inside are known; the folder's own registration never arrived.
        for name in ["plakat.txt", "beileger.txt"] {
            let path = "Entwurf/\(name)"
            try store.upsert(node: Node(id: Namespace.nodeID(firstSeenPath: path),
                                        projectID: project.id, relativePath: path,
                                        isDirectory: false, firstSeenAt: t0, lastSeenAt: t0))
        }
        let folder = Namespace.nodeID(firstSeenPath: "Entwurf")
        var report = SyncReport()
        let record = LogRecord(sequence: 9, deviceID: UUID(), writtenAt: t0,
                               body: .nodeRename(NodeRenameRecord(id: folder, from: "Entwurf",
                                                                  to: "Final", at: t0,
                                                                  isDirectory: true)))
        try sync.apply(record, from: PeerLog(deviceID: UUID(), directory: URL(fileURLWithPath: "/tmp"),
                                             manifest: nil),
                       at: t0, report: &report)

        let viewer = UUID()
        #expect(try store.files(projectID: project.id, parentPath: "Final", viewer: viewer)
                    .map(\.node.name).sorted() == ["beileger.txt", "plakat.txt"])
        #expect(try store.files(projectID: project.id, parentPath: "Entwurf", viewer: viewer).isEmpty)
    }
}
