import Foundation
import Testing
@testable import MacBenchCore

private func makeTempRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "macbench-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeIdentity(name: String = "Alex") -> LocalIdentity {
    LocalIdentity(deviceName: "Test Mac", member: Member(name: name, colorHex: "#FF0000"))
}

private func sampleEntry(text: String) -> LogBody {
    .entry(EntryRecord(entry: Entry(projectID: UUID(), authorID: UUID(),
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    kind: .message, text: text)))
}

@Suite("Change log")
struct LogTests {

    @Test("A folder inside a project is told which project it belongs to")
    func findsEnclosingProject() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "Projekt", directoryHint: .isDirectory)
        let layout = project.appending(path: "Layout/Entwürfe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        #expect(LogLayout.enclosingProjectRoot(of: layout) == nil, "no history anywhere yet")

        _ = try DeviceLogWriter(root: project, identity: makeIdentity())
        #expect(LogLayout.enclosingProjectRoot(of: layout)?.standardizedFileURL
                == project.standardizedFileURL)
        #expect(LogLayout.enclosingProjectRoot(of: project) == nil,
                "the project itself is not inside anything")

        // A folder that already keeps its own history is where the others are
        // writing; sending this Mac somewhere else would split it again.
        _ = try DeviceLogWriter(root: layout, identity: makeIdentity())
        #expect(LogLayout.enclosingProjectRoot(of: layout) == nil)
    }

    @Test("Records survive a write/read round trip")
    func roundTrip() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity()
        let writer = try DeviceLogWriter(root: root, identity: identity)
        try await writer.append([sampleEntry(text: "erste Notiz"), sampleEntry(text: "zweite Notiz")])

        let peers = DeviceLogReader.peers(in: root)
        #expect(peers.count == 1)
        let result = DeviceLogReader.read(peer: peers[0], after: 0)
        #expect(result.records.count == 2)
        #expect(result.isComplete)
        #expect(result.lastSequence == 2)
        guard case .entry(let first) = result.records[0].body else {
            Issue.record("expected an entry record"); return
        }
        #expect(first.text == "erste Notiz")
    }

    @Test("A watermark skips records already applied")
    func incrementalRead() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try DeviceLogWriter(root: root, identity: makeIdentity())
        try await writer.append([sampleEntry(text: "a"), sampleEntry(text: "b")])
        try await writer.append([sampleEntry(text: "c")])

        let peer = DeviceLogReader.peers(in: root)[0]
        let result = DeviceLogReader.read(peer: peer, after: 2)
        #expect(result.records.count == 1)
        #expect(result.records.first?.sequence == 3)
    }

    @Test("Sequence numbers continue across a restart")
    func sequenceSurvivesRestart() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity()
        let first = try DeviceLogWriter(root: root, identity: identity)
        try await first.append([sampleEntry(text: "a")])

        let second = try DeviceLogWriter(root: root, identity: identity)
        try await second.append([sampleEntry(text: "b")])
        #expect(await second.lastSequence == 2)

        let result = DeviceLogReader.read(peer: DeviceLogReader.peers(in: root)[0], after: 0)
        #expect(result.records.count == 2)
        #expect(result.isComplete)
    }

    @Test("Segments rotate and stay readable as one stream")
    func segmentRotation() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity()
        let writer = try DeviceLogWriter(root: root, identity: identity)
        let filler = String(repeating: "x", count: 900)
        for _ in 0..<400 { try await writer.append([sampleEntry(text: filler)]) }

        let dir = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
        let segments = try FileManager.default
            .contentsOfDirectory(atPath: dir.path(percentEncoded: false))
            .filter(LogLayout.isSegment)
        #expect(segments.count > 1, "expected the log to roll over into several segments")

        let result = DeviceLogReader.read(peer: DeviceLogReader.peers(in: root)[0], after: 0)
        #expect(result.records.count == 400)
        #expect(result.isComplete)
    }

    @Test("A half-written last line is tolerated, a broken middle line is reported")
    func partialTail() throws {
        let good = LogRecord(sequence: 1, deviceID: UUID(), writtenAt: Date(), body: sampleEntry(text: "ok"))
        var data = try JSONCoding.encoder().encode(good)
        data.append(0x0A)
        data.append(contentsOf: Array(#"{"v":1,"id":"trunc"#.utf8))

        let (records, problem) = DeviceLogReader.parse(data, after: 0)
        #expect(records.count == 1)
        #expect(problem == nil, "an incomplete tail is normal mid-sync, not corruption")

        var broken = Data(#"{"nope":true}"#.utf8)
        broken.append(0x0A)
        broken.append(try JSONCoding.encoder().encode(good))
        broken.append(0x0A)
        let (records2, problem2) = DeviceLogReader.parse(broken, after: 0)
        #expect(records2.count == 1)
        #expect(problem2 != nil, "a broken line that is not the tail must be reported")
    }

    @Test("Missing sequence numbers are reported as gaps, not silently dropped")
    func gapDetection() {
        #expect(DeviceLogReader.findGaps(seen: [1, 2, 3], after: 0, claimed: 3).isEmpty)
        #expect(DeviceLogReader.findGaps(seen: [1, 4], after: 0, claimed: 4) == [2...3])
        #expect(DeviceLogReader.findGaps(seen: [1, 2], after: 0, claimed: 9) == [3...9])
        #expect(DeviceLogReader.findGaps(seen: [], after: 5, claimed: 5).isEmpty)
        #expect(DeviceLogReader.findGaps(seen: [7], after: 5, claimed: 8) == [6...6, 8...8])
    }

    /// A write can fail — a full disk, a folder briefly not writable while sync
    /// holds it. The records that failed were never on disk, and their numbers
    /// must not be spent: a manifest promising a number no segment holds is a
    /// gap that never closes, and the other Mac's watermark parks there for good.
    @Test("A write that fails leaves no hole in the numbering")
    func failedWriteLeavesNoGap() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity()
        let writer = try DeviceLogWriter(root: root, identity: identity)
        _ = try await writer.append([sampleEntry(text: "eins")])

        let segment = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
            .appending(path: LogLayout.segmentName(1)).path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: segment)
        await #expect(throws: LogError.self) {
            try await writer.append([sampleEntry(text: "zwei"), sampleEntry(text: "drei")])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: segment)
        _ = try await writer.append([sampleEntry(text: "vier")])

        let peer = try #require(DeviceLogReader.peers(in: root).first)
        let result = DeviceLogReader.read(peer: peer, after: 0)
        #expect(result.gaps.isEmpty, "\(result.gaps)")
        #expect(result.records.map(\.sequence) == [1, 2])
        #expect(peer.manifest?.lastSequence == 2)
    }

    /// An evicted manifest on a Mac that was offline, or one that is not
    /// readable for any other reason, used to look like a first start: counting
    /// began at one again, below where the other Mac's watermark already stood.
    @Test("A manifest that cannot be read stops the writer instead of counting from one")
    func unreadableManifestRefusesToWrite() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity()
        let first = try DeviceLogWriter(root: root, identity: identity)
        try await first.append([sampleEntry(text: "a"), sampleEntry(text: "b")])

        let manifest = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
            .appending(path: LogLayout.manifestName).path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: manifest)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest) }
        #expect(throws: LogError.self) { try DeviceLogWriter(root: root, identity: identity) }
    }

    @Test("A manifest that is gone or broken is rebuilt from the segments")
    func lostManifestIsRebuilt() async throws {
        for damage in ["deleted", "garbage"] {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let identity = makeIdentity()
            let first = try DeviceLogWriter(root: root, identity: identity)
            let filler = String(repeating: "x", count: 900)
            for _ in 0..<300 { try await first.append([sampleEntry(text: filler)]) }

            let manifest = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
                .appending(path: LogLayout.manifestName)
            if damage == "deleted" {
                try FileManager.default.removeItem(at: manifest)
            } else {
                try Data("{\"formatVersion\": 1, \"devi".utf8).write(to: manifest)
            }

            let second = try DeviceLogWriter(root: root, identity: identity)
            #expect(await second.lastSequence == 300, "\(damage)")
            try await second.append([sampleEntry(text: "danach")])

            let peer = try #require(DeviceLogReader.peers(in: root).first)
            #expect(peer.manifest?.segments.count ?? 0 > 1, "\(damage)")
            let result = DeviceLogReader.read(peer: peer, after: 0)
            #expect(result.records.map(\.sequence) == Array(1...301), "\(damage)")
            #expect(result.isComplete, "\(damage)")
        }
    }

    /// Records go to the segment first and the manifest after. A crash between
    /// the two left a manifest behind its own records, and the next start
    /// handed out their numbers a second time.
    @Test("Records the manifest does not know about yet are not numbered twice")
    func segmentsAheadOfManifest() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity()
        let first = try DeviceLogWriter(root: root, identity: identity)
        try await first.append([sampleEntry(text: "a")])
        let manifest = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
            .appending(path: LogLayout.manifestName)
        let stale = try Data(contentsOf: manifest)
        try await first.append([sampleEntry(text: "b"), sampleEntry(text: "c")])
        try stale.write(to: manifest)

        let second = try DeviceLogWriter(root: root, identity: identity)
        #expect(await second.lastSequence == 3)
        try await second.append([sampleEntry(text: "d")])
        let result = DeviceLogReader.read(peer: DeviceLogReader.peers(in: root)[0], after: 0)
        #expect(result.records.map(\.sequence) == [1, 2, 3, 4])
        #expect(result.isComplete)
    }

    /// A power cut in the middle of a write leaves half a record. Appending
    /// behind it made it a broken line in the middle, with the first new record
    /// on the same line — lost, and a gap the other Mac would wait at for good.
    @Test("Half a record left by a crash is cut off before the next append")
    func partialTailIsCutBeforeAppending() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity()
        let first = try DeviceLogWriter(root: root, identity: identity)
        try await first.append([sampleEntry(text: "a")])
        let segment = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
            .appending(path: LogLayout.segmentName(1))
        let handle = try FileHandle(forWritingTo: segment)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"seq":2,"trunc"#.utf8))
        try handle.close()

        let second = try DeviceLogWriter(root: root, identity: identity)
        try await second.append([sampleEntry(text: "b")])
        let result = DeviceLogReader.read(peer: DeviceLogReader.peers(in: root)[0], after: 0)
        #expect(result.records.map(\.sequence) == [1, 2])
        #expect(result.isComplete, "\(result.unreadable)")
    }

    @Test("Timestamps keep millisecond precision through the log")
    func timestampPrecision() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let text = JSONCoding.string(from: date)
        #expect(text.hasSuffix("Z"))
        let parsed = try #require(JSONCoding.date(from: text))
        #expect(abs(parsed.timeIntervalSince(date)) < 0.002)
    }
}

@Suite("Identity")
struct IdentityTests {
    @Test("Node ids are derived, so two machines mint the same one")
    func deterministicNodeIDs() {
        let a = Namespace.nodeID(firstSeenPath: "Kunde A/Layout/plakat.afdesign")
        let b = Namespace.nodeID(firstSeenPath: "Kunde A/Layout/plakat.afdesign")
        let other = Namespace.nodeID(firstSeenPath: "Kunde A/Layout/plakat2.afdesign")
        #expect(a == b)
        #expect(a != other)
        #expect(a.uuidString.dropFirst(14).first == "5", "must be a version 5 UUID")
    }

    @Test("Built-in categories have stable ids across machines")
    func builtInCategories() {
        let ids = Set(Category.builtIns.map(\.id))
        #expect(ids.count == Category.builtIns.count)
        #expect(Category.builtIns[0].id == Namespace.builtInCategoryID(slug: "feedback"))
    }

    @Test("The dedup key buckets a window, so both machines agree")
    func dedupKeyBuckets() {
        let node = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = DedupKey.make(nodeID: node, event: .modified, at: base)
        let b = DedupKey.make(nodeID: node, event: .modified, at: base.addingTimeInterval(60))
        let c = DedupKey.make(nodeID: node, event: .modified, at: base.addingTimeInterval(20 * 60 + 1))
        let d = DedupKey.make(nodeID: node, event: .created, at: base)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }
}

@Suite("Who this Mac is")
struct IdentityFileTests {

    @Test("An identity kept in the index by an older version moves into its own file")
    func adoptsLegacyIdentity() throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = IdentityFile(directory: dir)
        let legacy = makeIdentity()
        #expect(file.load(orAdopt: legacy) == legacy)
        #expect(file.load(orAdopt: nil) == legacy, "written to the file on the way")
        #expect(IdentityFile(directory: try makeTempRoot()).load(orAdopt: nil) == nil,
                "neither is a Mac that has not onboarded yet")
    }

    @Test("The file wins over what the index says")
    func fileWins() throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = IdentityFile(directory: dir)
        let kept = makeIdentity(name: "Anna")
        try file.save(kept)
        #expect(file.load(orAdopt: makeIdentity(name: "Ben")) == kept)
    }

    @Test("A broken file falls back to the index rather than to a new person")
    func brokenFileFallsBack() throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = IdentityFile(directory: dir)
        try Data("{\"deviceID\": ".utf8).write(to: file.url)
        let legacy = makeIdentity()
        #expect(file.load(orAdopt: legacy) == legacy)
        #expect(file.load(orAdopt: nil) == legacy, "and the file is whole again")
    }

    /// What this is for: an index that cannot be opened is deleted and started
    /// again, and who this Mac is must not go with it.
    @Test("A rebuilt index keeps the person and the device")
    func survivesIndexRebuild() throws {
        let dir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appending(path: "index.sqlite")
        let identity = makeIdentity()
        do {
            let store = try Store(url: index)
            try store.setSetting("local.identity", value: identity)
            _ = IdentityFile(directory: dir).load(orAdopt: try? store.setting("local.identity", as: LocalIdentity.self))
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: dir.appending(path: "index.sqlite" + suffix))
        }
        let fresh = try Store(url: index)
        let loaded = IdentityFile(directory: dir)
            .load(orAdopt: try? fresh.setting("local.identity", as: LocalIdentity.self))
        #expect(loaded == identity)
        #expect(loaded?.deviceID == identity.deviceID)
    }
}
