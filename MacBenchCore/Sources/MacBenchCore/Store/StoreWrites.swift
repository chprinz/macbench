import Foundation
import GRDB

public enum EntryMergeOutcome: Sendable, Equatable {
    case inserted
    case updated
    /// An entry already existed for this change; the newcomer replaced it and the
    /// old one is kept hidden for reference.
    case replacedExisting(UUID)
    /// The change was already recorded, by the machine it happened on.
    case duplicate(existing: UUID)
}

extension Store {

    // MARK: - People and categories

    public func upsert(member: Member, at date: Date = Date()) throws {
        try write { db in try MemberRow(member, updatedAt: date).save(db) }
    }

    public func members() throws -> [Member] {
        try read { db in try MemberRow.order(Column("name")).fetchAll(db).map(\.member) }
    }

    public func member(id: UUID) throws -> Member? {
        try read { db in try MemberRow.fetchOne(db, key: id)?.member }
    }

    public func upsert(category: Category) throws {
        try write { db in try CategoryRow(category).save(db) }
    }

    /// Creates the shipped categories if they are missing. Their ids are derived
    /// from their names, so running this on both machines produces one set.
    public func ensureBuiltInCategories() throws {
        try write { db in
            for category in Category.builtIns where try CategoryRow.fetchOne(db, key: category.id) == nil {
                var row = CategoryRow(category)
                row.isBuiltIn = true
                try row.insert(db)
            }
        }
    }

    public func categories(includeDeleted: Bool = false) throws -> [Category] {
        try read { db in
            var request = CategoryRow.order(Column("sortIndex"), Column("name"))
            if !includeDeleted { request = request.filter(Column("isDeleted") == false) }
            return try request.fetchAll(db).map(\.category)
        }
    }

    // MARK: - Projects

    public func addProject(_ project: Project, rootPath: String?, bookmark: Data?) throws {
        try write { db in
            let maxSort = try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM project") ?? 0
            try db.execute(sql: """
                INSERT INTO project (id, name, isArchived, addedAt, sortIndex, rootPath,
                                     rootBookmark, verbosity, excludedPaths)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, '[]')
                """, arguments: [project.id, project.name, project.isArchived, project.addedAt,
                                 maxSort + 1, rootPath, bookmark, Verbosity.everything.rawValue])
        }
    }

    public func projects(includeArchived: Bool = false) throws -> [Project] {
        try read { db in
            var request = ProjectRow.order(Column("sortIndex"), Column("name"))
            if !includeArchived { request = request.filter(Column("isArchived") == false) }
            return try request.fetchAll(db).map(\.project)
        }
    }

    public func projectLocation(_ id: UUID) throws -> (path: String?, bookmark: Data?)? {
        try read { db in
            guard let row = try ProjectRow.fetchOne(db, key: id) else { return nil }
            return (row.rootPath, row.rootBookmark)
        }
    }

    public func updateProjectLocation(_ id: UUID, path: String, bookmark: Data?) throws {
        try write { db in
            try db.execute(sql: "UPDATE project SET rootPath = ?, rootBookmark = ? WHERE id = ?",
                           arguments: [path, bookmark, id])
        }
    }

    public func renameProject(_ id: UUID, to name: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE project SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    public func setProjectArchived(_ id: UUID, _ archived: Bool) throws {
        try write { db in
            try db.execute(sql: "UPDATE project SET isArchived = ? WHERE id = ?", arguments: [archived, id])
        }
    }

    public func removeProject(_ id: UUID) throws {
        try write { db in _ = try ProjectRow.deleteOne(db, key: id) }
    }

    public func verbosity(for projectID: UUID) throws -> Verbosity {
        try read { db in
            let raw = try String.fetchOne(db, sql: "SELECT verbosity FROM project WHERE id = ?",
                                          arguments: [projectID])
            return raw.flatMap(Verbosity.init(rawValue:)) ?? .everything
        }
    }

    public func setVerbosity(_ verbosity: Verbosity, for projectID: UUID) throws {
        try write { db in
            try db.execute(sql: "UPDATE project SET verbosity = ? WHERE id = ?",
                           arguments: [verbosity.rawValue, projectID])
        }
    }

    public func excludedPaths(for projectID: UUID) throws -> Set<String> {
        try read { db in try ProjectRow.fetchOne(db, key: projectID)?.excluded ?? [] }
    }

    public func setExcludedPaths(_ paths: Set<String>, for projectID: UUID) throws {
        let json = String(decoding: try JSONEncoder().encode(paths.sorted()), as: UTF8.self)
        try write { db in
            try db.execute(sql: "UPDATE project SET excludedPaths = ? WHERE id = ?",
                           arguments: [json, projectID])
        }
    }

    public func fsEventCursor(for projectID: UUID) throws -> (eventID: UInt64?, lastScanAt: Date?) {
        try read { db in
            guard let row = try ProjectRow.fetchOne(db, key: projectID) else { return (nil, nil) }
            return (row.lastFSEventID.map(UInt64.init), row.lastScanAt)
        }
    }

    public func setFSEventCursor(_ eventID: UInt64?, scannedAt: Date, for projectID: UUID) throws {
        try write { db in
            try db.execute(sql: "UPDATE project SET lastFSEventID = ?, lastScanAt = ? WHERE id = ?",
                           arguments: [eventID.map(Int64.init), scannedAt, projectID])
        }
    }

    // MARK: - Peers

    public func peers(for projectID: UUID) throws -> [PeerState] {
        try read { db in
            try PeerRow.filter(Column("projectID") == projectID).fetchAll(db).map {
                PeerState(deviceID: $0.deviceID, memberID: $0.memberID, deviceName: $0.deviceName,
                          appliedSequence: $0.lastSequence, claimedSequence: $0.claimedSequence,
                          lastReadAt: $0.lastReadAt)
            }
        }
    }

    public func updatePeer(projectID: UUID, deviceID: UUID, memberID: UUID?, deviceName: String?,
                           appliedSequence: Int, claimedSequence: Int, at date: Date) throws {
        try write { db in
            try PeerRow(projectID: projectID, deviceID: deviceID, memberID: memberID,
                        deviceName: deviceName, lastSequence: appliedSequence,
                        claimedSequence: claimedSequence, lastReadAt: date).save(db)
        }
    }

    // MARK: - Nodes

    public func upsert(node: Node, inode: Int64? = nil) throws {
        try write { db in try Store.upsert(node: node, inode: inode, in: db) }
    }

    /// Indexes a batch of nodes in one transaction.
    ///
    /// The first look at a folder is the one moment somebody is watching a
    /// progress line, and a separate write per file is most of what they are
    /// waiting for: sixteen thousand of them cost three seconds of pure
    /// transaction overhead.
    public func upsert(nodes: [IndexedNode]) throws {
        guard !nodes.isEmpty else { return }
        try write { db in
            for entry in nodes { try Store.upsert(node: entry.node, inode: entry.inode, in: db) }
        }
    }

    static func upsert(node: Node, inode: Int64?, in db: Database) throws {
        // Scoped to the project. Looking the id up on its own let one project's
        // file be dragged into another's, because an id derived from "Briefing.pdf"
        // is the same id in every client folder. Ids are salted apart when they are
        // minted, so a conflict here is a mistake rather than something to absorb:
        // the insert throws, and the file stays unindexed instead of stealing a row.
        if var existing = try NodeRow
            .filter(Column("id") == node.id)
            .filter(Column("projectID") == node.projectID)
            .fetchOne(db) {
            existing.relativePath = node.relativePath
            existing.parentPath = node.parentPath ?? ""
            existing.name = node.name
            existing.searchName = searchNormalized(node.name)
            existing.state = node.state.rawValue
            existing.lastSeenAt = node.lastSeenAt
            existing.isDirectory = node.isDirectory
            // Without these two a catch-up scan would report the same change again
            // on every run: the comparison is against exactly these values.
            if let modified = node.contentModifiedAt { existing.contentModifiedAt = modified }
            if let size = node.fileSize { existing.fileSize = size }
            if let inode { existing.inode = inode }
            try existing.update(db)
        } else {
            try NodeRow(node, inode: inode).insert(db)
        }
    }

    public func node(id: UUID) throws -> Node? {
        try read { db in try Store.resolveNode(id: id, in: db)?.node }
    }

    /// Whether any project holds this id. Used when minting one, where the only
    /// question is whether it is free.
    public func anyNode(id: UUID) throws -> Node? {
        try read { db in try NodeRow.fetchOne(db, key: id)?.node }
    }

    public func node(projectID: UUID, relativePath: String) throws -> Node? {
        try read { db in
            try NodeRow.filter(Column("projectID") == projectID)
                .filter(Column("relativePath") == relativePath).fetchOne(db)?.node
        }
    }

    /// The node an id from a peer's log means, inside one project.
    ///
    /// Scoped on purpose. An id is derived from the relative path, so the same id
    /// can name a real file in another project — every client folder has a
    /// `Briefing.pdf`. Resolving a peer's id without saying which project it came
    /// from lands the entry on the other client's file.
    public func node(id: UUID, projectID: UUID) throws -> Node? {
        try read { db in try Store.resolveNode(id: id, projectID: projectID, in: db)?.node }
    }

    /// Follows alias redirects, so an id from an old log entry still lands on the
    /// node it became.
    static func resolveNode(id: UUID, projectID: UUID? = nil,
                            in db: Database) throws -> NodeRow? {
        var current = id
        for _ in 0..<8 {
            if let row = try NodeRow.fetchOne(db, key: current),
               projectID == nil || row.projectID == projectID {
                return row
            }
            let next: UUID?
            if let projectID {
                next = try UUID.fetchOne(db, sql: """
                    SELECT winner FROM nodeAlias WHERE loser = ? AND projectID = ?
                    """, arguments: [current, projectID])
            } else {
                next = try UUID.fetchOne(db, sql: "SELECT winner FROM nodeAlias WHERE loser = ?",
                                         arguments: [current])
            }
            guard let next else { return nil }
            current = next
        }
        return nil
    }

    /// Records the file's own modification date and size as indexed.
    ///
    /// This is what a catch-up scan compares against, so it is the marker for
    /// "this version of the file has been accounted for". It is written after the
    /// entry, never before: a change that was seen but not yet written must still
    /// look unaccounted-for to the next scan, or quitting the app in the twenty
    /// minutes a quiet change is being gathered loses it for good.
    public func markContentIndexed(nodeID: UUID, modifiedAt: Date?, size: Int64?) throws {
        guard modifiedAt != nil || size != nil else { return }
        try write { db in
            guard var row = try Store.resolveNode(id: nodeID, in: db) else { return }
            if let modifiedAt { row.contentModifiedAt = modifiedAt }
            if let size { row.fileSize = size }
            try row.update(db)
        }
    }

    public func setNodeState(_ state: NodeState, id: UUID, at date: Date) throws {
        try write { db in
            try db.execute(sql: "UPDATE node SET state = ?, lastSeenAt = ? WHERE id = ?",
                           arguments: [state.rawValue, date, id])
        }
    }

    /// Moves a node and everything under it, keeping every id — which is what
    /// keeps the history attached after a reorganisation.
    public func moveNode(id: UUID, to newPath: String, at date: Date) throws {
        try write { db in try Store.moveNode(id: id, to: newPath, at: date, in: db) }
    }

    static func moveNode(id: UUID, to newPath: String, at date: Date, in db: Database) throws {
        guard var row = try resolveNode(id: id, in: db) else { return }
        let oldPath = row.relativePath
        guard oldPath != newPath else { return }

        if row.isDirectory {
            let descendants = try NodeRow
                .filter(Column("projectID") == row.projectID)
                .filter(Column("relativePath") >= oldPath + "/")
                .filter(Column("relativePath") < oldPath + "0")
                .fetchAll(db)
            for var child in descendants {
                let suffix = String(child.relativePath.dropFirst(oldPath.count))
                child.relativePath = newPath + suffix
                try vacate(child.relativePath, projectID: child.projectID, for: child.id, in: db)
                child.parentPath = (child.relativePath as NSString).deletingLastPathComponent
                child.name = (child.relativePath as NSString).lastPathComponent
                child.searchName = searchNormalized(child.name)
                child.lastSeenAt = date
                try child.update(db)
            }
        }
        try vacate(newPath, projectID: row.projectID, for: row.id, in: db)
        row.relativePath = newPath
        row.parentPath = (newPath as NSString).deletingLastPathComponent
        row.name = (newPath as NSString).lastPathComponent
        row.searchName = searchNormalized(row.name)
        row.lastSeenAt = date
        try row.update(db)
    }

    /// Makes room at `path` for the node moving there. One path, one node.
    ///
    /// Whatever still holds it gives it up by becoming a redirect to the node
    /// that arrives: usually a deleted file whose name is being reused — delete
    /// the old poster, rename the new one to its name — sometimes a stub, or this
    /// Mac's own id for a file the other Mac knew first. What was said about it
    /// stays reachable, on the file that now carries the name. Left in place, the
    /// move broke the one-node-per-path rule and threw; on the receiving Mac that
    /// stopped the read at that record, for good.
    static func vacate(_ path: String, projectID: UUID, for mover: UUID, in db: Database) throws {
        guard let occupant = try NodeRow
            .filter(Column("projectID") == projectID)
            .filter(Column("relativePath") == path)
            .fetchOne(db), occupant.id != mover else { return }
        try alias(projectID: projectID, loser: occupant.id, winner: mover, in: db)
    }

    /// Marks everything under a folder as gone, for a folder that went as a
    /// whole — to the Trash, or out of the project — which is one event and says
    /// nothing about what was inside it.
    public func markDescendantsDeleted(projectID: UUID, folderPath: String, at date: Date) throws {
        guard !folderPath.isEmpty else { return }
        try write { db in
            try db.execute(sql: """
                UPDATE node SET state = ?, lastSeenAt = ?
                 WHERE projectID = ? AND state = ? AND relativePath >= ? AND relativePath < ?
                """, arguments: [NodeState.deleted.rawValue, date, projectID,
                                 NodeState.present.rawValue, folderPath + "/", folderPath + "0"])
        }
    }

    /// Moves long-deleted nodes into the archive.
    ///
    /// Kept local and never written to the log: both machines run the same rule
    /// over the same data, so they reach the same answer without talking, and a
    /// person who sets a different retention does not impose it on the other.
    /// Nothing is removed — the history of an archived node is still there, it
    /// just stops appearing in the tree, the file lists and search.
    @discardableResult
    public func archiveDeletedNodes(olderThan days: Int, now: Date = Date()) throws -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 3600)
        return try write { db in
            try db.execute(sql: """
                UPDATE node SET state = ? WHERE state = ? AND lastSeenAt < ?
                """, arguments: [NodeState.archived.rawValue, NodeState.deleted.rawValue, cutoff])
            return db.changesCount
        }
    }

    /// Redirects one node id onto another, within one project.
    ///
    /// Everything here is per project. The loser's row is only removed if it is
    /// this project's — the same id can be a perfectly good file in another one,
    /// and deleting that was how a second client's `Briefing.pdf` disappeared.
    public func aliasNode(projectID: UUID, loser: UUID, winner: UUID) throws {
        guard loser != winner else { return }
        try write { db in try Store.alias(projectID: projectID, loser: loser, winner: winner, in: db) }
    }

    static func alias(projectID: UUID, loser: UUID, winner: UUID, in db: Database) throws {
        guard loser != winner else { return }
        try db.execute(sql: """
            INSERT OR REPLACE INTO nodeAlias (projectID, loser, winner) VALUES (?, ?, ?)
            """, arguments: [projectID, loser, winner])
        try db.execute(sql: "UPDATE entry SET nodeID = ? WHERE nodeID = ? AND projectID = ?",
                       arguments: [winner, loser, projectID])
        try db.execute(sql: "DELETE FROM node WHERE id = ? AND projectID = ?",
                       arguments: [loser, projectID])
    }

    /// Drops the local file identity of a node and everything under it: the file
    /// at that path has not been seen on this disk.
    public func forgetInode(projectID: UUID, path: String) throws {
        try write { db in
            try db.execute(sql: """
                UPDATE node SET inode = NULL
                 WHERE projectID = ? AND (relativePath = ? OR (relativePath >= ? AND relativePath < ?))
                """, arguments: [projectID, path, path + "/", path + "0"])
        }
    }

    // MARK: - Document packages

    /// Turns what an earlier version indexed as folders back into documents.
    ///
    /// Every file inside a package goes, and with it every system entry about it:
    /// "Index.zip changed" was never something anyone did. Anything a person wrote
    /// against one of those files moves to the document itself. Idempotent, so it
    /// runs on every start rather than once behind a flag.
    @discardableResult
    public func foldDocumentPackages(projectID: UUID) throws -> Int {
        try write { db in
            let rows = try NodeRow.filter(Column("projectID") == projectID).fetchAll(db)
            let byPath = Dictionary(rows.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            var folded = 0
            for var row in rows {
                guard let root = DocumentPackage.root(of: row.relativePath) else { continue }
                if root == row.relativePath {
                    if row.isDirectory {
                        row.isDirectory = false
                        try row.update(db)
                    }
                    continue
                }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO packageInterior (projectID, nodeID, packagePath)
                    VALUES (?, ?, ?)
                    """, arguments: [projectID, row.id, root])
                // What happened inside becomes what happened to the document: one
                // save, one line, and whoever had already read it still has.
                let changes = try EntryRow
                    .filter(Column("nodeID") == row.id)
                    .filter(Column("kind") == EntryKind.system.rawValue)
                    .filter(Column("isSuperseded") == false)
                    .fetchAll(db)
                for change in changes {
                    guard let packageID = byPath[root]?.id,
                          let save = Store.packageSave(for: change.entry, packageID: packageID)
                    else { continue }
                    let survivor: UUID
                    switch try Store.merge(entry: save, categories: [], in: db) {
                    case .duplicate(let existing): survivor = existing
                    default: survivor = save.id
                    }
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO readState (entryID, memberID, readAt)
                        SELECT ?, memberID, readAt FROM readState WHERE entryID = ?
                        """, arguments: [survivor, change.id])
                }
                try db.execute(sql: "DELETE FROM entry WHERE nodeID = ? AND kind = ?",
                               arguments: [row.id, EntryKind.system.rawValue])
                try db.execute(sql: "UPDATE entry SET nodeID = ? WHERE nodeID = ?",
                               arguments: [byPath[root]?.id, row.id])
                try db.execute(sql: "DELETE FROM node WHERE id = ? AND projectID = ?",
                               arguments: [row.id, projectID])
                folded += 1
            }
            return folded
        }
    }

    /// What a change to a file inside a package says about the package: that it
    /// was saved. Keyed like any other change to it, so the dozen files one save
    /// touches land on one entry, on both machines. A file vanishing from inside
    /// says nothing of its own — every save that removes one also writes the
    /// index — and it is what made one Mac's stale copy read as a deletion.
    static func packageSave(for entry: Entry, packageID: UUID) -> Entry? {
        guard entry.kind == .system, let event = entry.event, event.type != .removed else { return nil }
        return Entry(projectID: entry.projectID, nodeID: packageID, authorID: entry.authorID,
                     createdAt: entry.createdAt, observedAt: entry.observedAt, kind: .system,
                     text: "", event: FileEvent(type: .modified, backfilled: event.backfilled),
                     dedupKey: DedupKey.make(nodeID: packageID, event: .modified, at: entry.createdAt))
    }

    public func markPackageInterior(projectID: UUID, nodeID: UUID, packagePath: String) throws {
        try write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO packageInterior (projectID, nodeID, packagePath)
                VALUES (?, ?, ?)
                """, arguments: [projectID, nodeID, packagePath])
        }
    }

    /// The package a peer's node id was inside, if it was one of those.
    public func packageInterior(projectID: UUID, nodeID: UUID) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: """
                SELECT packagePath FROM packageInterior WHERE projectID = ? AND nodeID = ?
                """, arguments: [projectID, nodeID])
        }
    }

    // MARK: - Entries

    /// The single funnel for every entry, whether it came from this machine or
    /// from a peer's log. Everything about duplicate suppression lives here.
    @discardableResult
    public func merge(entry: Entry, categories: Set<UUID>? = nil) throws -> EntryMergeOutcome {
        try write { db in try Store.merge(entry: entry, categories: categories, in: db) }
    }

    static func merge(entry: Entry, categories: Set<UUID>?, in db: Database) throws -> EntryMergeOutcome {
        let categoryIDs = categories ?? entry.categoryIDs

        if let existing = try EntryRow.fetchOne(db, key: entry.id) {
            // Seen before. A record is never rewritten, so this is a log being read
            // again — past a hole that is still open, the entries beyond it come
            // round on every pull. What was changed about the entry since stays
            // changed, and when it first arrived here stays when it arrived: taking
            // the record's word for either reopened tasks somebody had ticked off
            // and announced old messages as new.
            var row = EntryRow(entry)
            row.observedAt = existing.observedAt
            row.isSuperseded = existing.isSuperseded
            row.isRetracted = existing.isRetracted
            row.patchedAt = existing.patchedAt
            row.textEditedAt = existing.textEditedAt ?? entry.textEditedAt
            if existing.patchedAt != nil {
                row.text = existing.text
                row.searchText = existing.searchText
                row.isTask = existing.isTask
                row.isDone = existing.isDone
                row.assigneeID = existing.assigneeID
                row.replyToID = existing.replyToID
                try row.update(db)
                return .updated
            }
            try row.update(db)
            try writeCategories(categoryIDs, for: entry.id, in: db)
            return .updated
        }

        if let key = entry.dedupKey {
            // Within the project, because a business key only has to be unique
            // where it is read. A key built from a node id would be unique
            // anywhere — those are salted apart across projects — but one built
            // from a person is not: joining two projects is two facts.
            let rivals = try EntryRow
                .filter(Column("dedupKey") == key)
                .filter(Column("projectID") == entry.projectID)
                .filter(Column("isSuperseded") == false)
                .fetchAll(db)
            if let rival = rivals.first {
                if preferred(entry, over: rival.entry) {
                    // The newcomer is the better record — usually because it knows
                    // who made the change and the local one did not.
                    try db.execute(sql: "UPDATE entry SET isSuperseded = 1 WHERE id = ?",
                                   arguments: [rival.id])
                    try EntryRow(entry).insert(db)
                    try writeCategories(categoryIDs, for: entry.id, in: db)
                    try db.execute(sql: "UPDATE readState SET entryID = ? WHERE entryID = ?",
                                   arguments: [entry.id, rival.id])
                    return .replacedExisting(rival.id)
                }
                var loser = EntryRow(entry)
                loser.isSuperseded = true
                try loser.insert(db)
                return .duplicate(existing: rival.id)
            }
        }

        try EntryRow(entry).insert(db)
        try writeCategories(categoryIDs, for: entry.id, in: db)
        return .inserted
    }

    /// Decides which of two records for the same change survives.
    ///
    /// Only data both machines have may be used here, otherwise they reach
    /// different verdicts and the duplicate comes back. `observedAt` is local, so
    /// it is deliberately not consulted.
    static func preferred(_ candidate: Entry, over existing: Entry) -> Bool {
        if (candidate.authorID != nil) != (existing.authorID != nil) {
            return candidate.authorID != nil
        }
        if candidate.createdAt != existing.createdAt {
            return candidate.createdAt < existing.createdAt
        }
        return candidate.id.uuidString < existing.id.uuidString
    }

    static func writeCategories(_ ids: Set<UUID>, for entryID: UUID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM entryCategory WHERE entryID = ?", arguments: [entryID])
        for id in ids {
            try EntryCategoryRow(entryID: entryID, categoryID: id).insert(db)
        }
    }

    public func entry(id: UUID) throws -> Entry? {
        try read { db in try EntryRow.fetchOne(db, key: id)?.entry }
    }

    /// Applies a field-level change from a log record. Last writer wins per entry,
    /// ordered by the log timestamp rather than by arrival.
    public func apply(patch: EntryPatchRecord, at date: Date) throws {
        try write { db in
            guard var row = try EntryRow.fetchOne(db, key: patch.entryID) else { return }
            if let patched = row.patchedAt, patched > date { return }
            if let text = patch.text {
                row.text = text
                row.searchText = searchNormalized(text)
                row.textEditedAt = date
            }
            if let isTask = patch.isTask { row.isTask = isTask }
            if let isDone = patch.isDone { row.isDone = isDone }
            if let assignee = patch.assigneeID { row.assigneeID = assignee }
            if let replyTo = patch.replyToID { row.replyToID = replyTo }
            if let retracted = patch.isRetracted { row.isRetracted = retracted }
            row.patchedAt = date
            try row.update(db)
            if let categories = patch.categoryIDs {
                try Store.writeCategories(Set(categories), for: patch.entryID, in: db)
            }
        }
    }

    // MARK: - Read state

    public func markRead(entryIDs: [UUID], member: UUID, at date: Date = Date()) throws {
        guard !entryIDs.isEmpty else { return }
        try write { db in
            for id in entryIDs {
                try db.execute(sql: """
                    INSERT INTO readState (entryID, memberID, readAt) VALUES (?, ?, ?)
                    ON CONFLICT (entryID, memberID) DO NOTHING
                    """, arguments: [id, member, date])
            }
        }
    }

    /// A file's changes, without what was written about it. Picking a file is
    /// looking at its changes — the row already says what they were — while a
    /// message still has to be on screen to count as read.
    public func markChangesRead(nodeID: UUID, member: UUID, at date: Date = Date()) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO readState (entryID, memberID, readAt)
                SELECT id, ?, ? FROM entry
                WHERE nodeID = ? AND kind <> 'message' AND isSuperseded = 0 AND isRetracted = 0
                ON CONFLICT (entryID, memberID) DO NOTHING
                """, arguments: [member, date, nodeID])
        }
    }

    public func markAllRead(projectID: UUID?, member: UUID, at date: Date = Date()) throws {
        try write { db in
            let sql = """
                INSERT INTO readState (entryID, memberID, readAt)
                SELECT id, ?, ? FROM entry
                WHERE isSuperseded = 0 AND isRetracted = 0
                  \(projectID == nil ? "" : "AND projectID = ?")
                ON CONFLICT (entryID, memberID) DO NOTHING
                """
            var args: [any DatabaseValueConvertible] = [member, date]
            if let projectID { args.append(projectID) }
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: - Local settings

    public func setting<T: Codable & Sendable>(_ key: String, as type: T.Type) throws -> T? {
        try read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM localSetting WHERE key = ?",
                                               arguments: [key]) else { return nil }
            return try? JSONCoding.decoder().decode(T.self, from: data)
        }
    }

    public func setSetting<T: Codable & Sendable>(_ key: String, value: T) throws {
        let data = try JSONCoding.encoder().encode(value)
        try write { db in
            try db.execute(sql: """
                INSERT INTO localSetting (key, value) VALUES (?, ?)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value
                """, arguments: [key, data])
        }
    }
}

/// A node and the local-only inode that goes with it, for batch indexing.
public struct IndexedNode: Sendable {
    public var node: Node
    public var inode: Int64?
    public init(node: Node, inode: Int64?) {
        self.node = node
        self.inode = inode
    }
}

public struct PeerState: Sendable, Hashable {
    public var deviceID: UUID
    public var memberID: UUID?
    public var deviceName: String?
    public var appliedSequence: Int
    public var claimedSequence: Int
    public var lastReadAt: Date?
    /// The peer says it has written more than we have managed to read. Normal for
    /// a moment after a change; a standing complaint means sync is stuck.
    public var isBehind: Bool { claimedSequence > appliedSequence }
}
