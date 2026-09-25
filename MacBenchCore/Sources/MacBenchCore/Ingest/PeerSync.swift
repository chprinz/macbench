import Foundation

public struct SyncReport: Sendable, Hashable {
    public var appliedRecords = 0
    public var newEntries = 0
    /// Peers whose logs promise more than we could read. Shown to the user, because
    /// "sync is behind" and "there is nothing new" must never look the same.
    public var incompletePeers: [PeerProblem] = []
    public var checkedAt: Date = .distantPast

    public var isHealthy: Bool { incompletePeers.isEmpty }
}

public struct PeerProblem: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case waitingForDownload(files: Int)
        case missingRecords(count: Int)
        case unreadable(String)
        case newerFormat(Int)
    }
    public var deviceName: String
    public var memberName: String?
    public var kind: Kind
}

/// Reads the other machines' logs and folds them into the local index.
public struct PeerSync: Sendable {
    let store: Store
    let projectID: UUID
    let selfDeviceID: UUID

    public init(store: Store, projectID: UUID, selfDeviceID: UUID) {
        self.store = store
        self.projectID = projectID
        self.selfDeviceID = selfDeviceID
    }

    @discardableResult
    public func pull(root: URL, now: Date = Date()) throws -> SyncReport {
        var report = SyncReport()
        report.checkedAt = now
        let watermarks = try store.peers(for: projectID)
            .reduce(into: [UUID: Int]()) { $0[$1.deviceID] = $1.appliedSequence }

        for peer in DeviceLogReader.peers(in: root) where peer.deviceID != selfDeviceID {
            let after = watermarks[peer.deviceID] ?? 0
            let result = DeviceLogReader.read(peer: peer, after: after)
            let name = peer.manifest?.deviceName ?? peer.deviceID.uuidString
            let memberName = peer.manifest?.member.name

            if let version = result.incompatibleFormat {
                report.incompletePeers.append(.init(deviceName: name, memberName: memberName,
                                                    kind: .newerFormat(version)))
                continue
            }
            if let member = peer.manifest?.member { try store.upsert(member: member, at: now) }

            // A record that cannot be applied stops this Mac's log where it is,
            // and only this one's. The error used to leave `pull` altogether:
            // every Mac read after it was never read at all, and the reason went
            // into a status nobody was shown.
            var applied: [LogRecord] = []
            var failure: (sequence: Int, reason: String)?
            for record in result.records {
                do {
                    try apply(record, from: peer, at: now, report: &report)
                } catch {
                    failure = (record.sequence, error.localizedDescription)
                    break
                }
                applied.append(record)
                report.appliedRecords += 1
            }

            // The watermark only advances past a contiguous run. A gap keeps it
            // parked, so the missing records are re-read once sync delivers them
            // instead of being skipped forever — and so does a record that failed,
            // which is tried again on the next pass.
            let watermark = advanceWatermark(from: after, records: applied, gaps: result.gaps)
            try store.updatePeer(projectID: projectID, deviceID: peer.deviceID,
                                 memberID: peer.manifest?.member.id, deviceName: name,
                                 appliedSequence: watermark,
                                 claimedSequence: peer.manifest?.lastSequence ?? watermark, at: now)
            if let failure {
                report.incompletePeers.append(.init(deviceName: name, memberName: memberName,
                    kind: .unreadable("record \(failure.sequence): \(failure.reason)")))
            }

            if !result.pendingDownloads.isEmpty {
                report.incompletePeers.append(.init(deviceName: name, memberName: memberName,
                    kind: .waitingForDownload(files: result.pendingDownloads.count)))
            }
            if !result.gaps.isEmpty {
                let missing = result.gaps.reduce(0) { $0 + $1.count }
                report.incompletePeers.append(.init(deviceName: name, memberName: memberName,
                                                    kind: .missingRecords(count: missing)))
            }
            for (file, problem) in result.unreadable {
                report.incompletePeers.append(.init(deviceName: name, memberName: memberName,
                                                    kind: .unreadable("\(file): \(problem)")))
            }
        }
        return report
    }

    func advanceWatermark(from start: Int, records: [LogRecord], gaps: [ClosedRange<Int>]) -> Int {
        var applied = start
        for record in records.sorted(by: { $0.sequence < $1.sequence }) {
            if record.sequence == applied + 1 { applied = record.sequence } else { break }
        }
        if let firstGap = gaps.map(\.lowerBound).min() { applied = min(applied, firstGap - 1) }
        return applied
    }

    func apply(_ record: LogRecord, from peer: PeerLog, at now: Date, report: inout SyncReport) throws {
        switch record.body {
        case .member(let member):
            try store.upsert(member: member, at: record.writtenAt)

        case .category(let category):
            try store.upsert(category: category)

        case .node(let node):
            // A version from before packages were documents registers every file
            // inside them. Those ids are remembered, not indexed.
            if let package = interiorPackage(of: node.path) {
                try store.markPackageInterior(projectID: projectID, nodeID: node.id,
                                              packagePath: package)
                return
            }
            try ensureNode(id: node.id, path: node.path,
                           isDirectory: node.isDirectory && !DocumentPackage.isPackage(node.path),
                           firstSeenAt: node.firstSeenAt, at: now)

        case .nodeRename(let rename):
            if let package = interiorPackage(of: rename.from) ?? interiorPackage(of: rename.to) {
                try store.markPackageInterior(projectID: projectID, nodeID: rename.id,
                                              packagePath: package)
                return
            }
            // A folder taken for a file is moved on its own and leaves everything
            // inside it behind at the old path.
            try ensureNode(id: rename.id, path: rename.from,
                           isDirectory: (rename.isDirectory ?? false)
                               && !DocumentPackage.isPackage(rename.from),
                           firstSeenAt: rename.at, at: now)
            let local = localID(for: rename.id)
            let before = try store.node(id: local, projectID: projectID)
            try store.moveNode(id: local, to: rename.to, at: rename.at)
            if let before, before.relativePath != rename.to {
                // This disk has not been seen to follow yet. Until it does, a file
                // missing at the new name is our copy lagging, not a deletion.
                try store.forgetInode(projectID: projectID, path: rename.to)
            }

        case .nodeState(let state):
            if try store.packageInterior(projectID: projectID, nodeID: state.id) != nil { return }
            try store.setNodeState(state.state, id: localID(for: state.id), at: state.at)

        case .nodeAlias(let alias):
            try store.aliasNode(projectID: projectID, loser: alias.loser,
                                winner: localID(for: alias.winner))

        case .entry(let entryRecord):
            var entry = entryRecord.entry(projectID: projectID, observedAt: now)
            if let peerNodeID = entry.nodeID,
               let package = try store.packageInterior(projectID: projectID, nodeID: peerNodeID) {
                // "Index.zip changed" is not something anybody did; the document
                // being saved is. What a person wrote belongs to the document too.
                let packageID = try store.node(projectID: projectID, relativePath: package)?.id
                if entry.kind == .system {
                    guard let packageID, let save = Store.packageSave(for: entry, packageID: packageID)
                    else { return }
                    entry = save
                } else {
                    entry.nodeID = packageID
                }
            } else if let peerNodeID = entry.nodeID {
                // The peer's id, read as this project means it. Without the scope an
                // id derived from "Briefing.pdf" lands on whichever client folder
                // happened to be indexed first.
                var local = localID(for: peerNodeID)
                if try store.node(id: local, projectID: projectID) == nil {
                    // The entry names a file whose registration has not arrived yet.
                    // Keep a stub so the entry is not orphaned; the real record fills
                    // in the path when it turns up.
                    local = try freeID(preferring: local, path: Node.placeholderPath(for: peerNodeID))
                    try store.upsert(node: Node(id: local, projectID: projectID,
                                                relativePath: Node.placeholderPath(for: local),
                                                isDirectory: false,
                                                firstSeenAt: entry.createdAt, lastSeenAt: now))
                    if local != peerNodeID {
                        try store.aliasNode(projectID: projectID, loser: peerNodeID, winner: local)
                    }
                }
                entry.nodeID = local
            }
            if case .inserted = try store.merge(entry: entry) { report.newEntries += 1 }

        case .entryPatch(let patch):
            try store.apply(patch: patch, at: record.writtenAt)
        }
    }

    private func interiorPackage(of path: String) -> String? {
        guard let root = DocumentPackage.root(of: path), root != path else { return nil }
        return root
    }

    /// What a node id from a peer's log means here.
    ///
    /// Usually itself. It differs when the id is already spoken for locally by a
    /// file in another project — ids come from the relative path, and two clients
    /// both have a `Briefing.pdf` — in which case a redirect for this project says
    /// which node was put in its place.
    func localID(for id: UUID) -> UUID {
        (try? store.node(id: id, projectID: projectID))?.id ?? id
    }

    /// Both machines derive node ids from the path a file was first seen at, so
    /// they normally agree without talking. When a rename happened before one of
    /// them ever indexed the file, they do not — and the older registration wins,
    /// on both machines, without either having to ask.
    func ensureNode(id: UUID, path: String, isDirectory: Bool,
                    firstSeenAt: Date, at now: Date) throws {
        if let existing = try store.node(id: id, projectID: projectID) {
            if existing.isPlaceholder {
                try store.moveNode(id: existing.id, to: path, at: now)
            }
            return
        }
        // The id may be free here, or it may belong to a different project's file.
        // In the second case this project needs one of its own, and a redirect so
        // that records naming the peer's id still find it.
        let free = try freeID(preferring: id, path: path)

        if let rival = try store.node(projectID: projectID, relativePath: path), rival.id != free {
            let incomingWins = firstSeenAt < rival.firstSeenAt
                || (firstSeenAt == rival.firstSeenAt && id.uuidString < rival.id.uuidString)
            if incomingWins {
                // The rival row has to go before the winner can take its path:
                // one path, one node.
                try store.aliasNode(projectID: projectID, loser: rival.id, winner: free)
                try store.upsert(node: Node(id: free, projectID: projectID, relativePath: path,
                                            isDirectory: isDirectory, firstSeenAt: firstSeenAt,
                                            lastSeenAt: now))
                if free != id { try store.aliasNode(projectID: projectID, loser: id, winner: free) }
            } else {
                try store.aliasNode(projectID: projectID, loser: id, winner: rival.id)
            }
            return
        }
        try store.upsert(node: Node(id: free, projectID: projectID, relativePath: path,
                                    isDirectory: isDirectory, firstSeenAt: firstSeenAt,
                                    lastSeenAt: now))
        if free != id { try store.aliasNode(projectID: projectID, loser: id, winner: free) }
    }

    /// An id this project can use: the peer's own, or a salted one derived the
    /// same way `ProjectEngine` salts, when another project already holds it.
    private func freeID(preferring id: UUID, path: String) throws -> UUID {
        guard try store.anyNode(id: id) != nil else { return id }
        for salt in 1...16 {
            let candidate = Namespace.nodeID(firstSeenPath: "\(path)#\(salt)")
            if try store.anyNode(id: candidate) == nil { return candidate }
        }
        return id
    }
}
