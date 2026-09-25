import Foundation
import GRDB

/// The local index.
///
/// It is a cache, not the archive: everything in here can be rebuilt from the
/// change logs in the project folders. That is deliberate — a corrupt index is
/// then a nuisance, not a loss.
public final class Store: Sendable {
    public let writer: any DatabaseWriter

    public init(url: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try DatabasePool(path: url.path(percentEncoded: false), configuration: config)
        try Store.migrator.migrate(writer)
    }

    public init(inMemoryNamed name: String = UUID().uuidString) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabaseQueue(named: name, configuration: config)
        try Store.migrator.migrate(writer)
    }

    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    @discardableResult
    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "member") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("addedAt", .datetime).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                // Local only. An absolute path contains the account name and a
                // security-scoped bookmark is bound to this Mac, so neither of these
                // ever goes into the log.
                t.column("rootPath", .text)
                t.column("rootBookmark", .blob)
                t.column("verbosity", .text).notNull().defaults(to: Verbosity.everything.rawValue)
                t.column("lastFSEventID", .integer)
                t.column("lastScanAt", .datetime)
                t.column("excludedPaths", .text).notNull().defaults(to: "[]")
            }

            try db.create(table: "projectPeer") { t in
                t.column("projectID", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("deviceID", .text).notNull()
                t.column("memberID", .text)
                t.column("deviceName", .text)
                t.column("lastSequence", .integer).notNull().defaults(to: 0)
                t.column("claimedSequence", .integer).notNull().defaults(to: 0)
                t.column("lastReadAt", .datetime)
                t.primaryKey(["projectID", "deviceID"])
            }

            try db.create(table: "node") { t in
                t.primaryKey("id", .text)
                t.column("projectID", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.column("parentPath", .text).notNull()
                t.column("name", .text).notNull()
                t.column("searchName", .text).notNull()
                t.column("isDirectory", .boolean).notNull()
                t.column("state", .text).notNull()
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                // Last known content state, so a catch-up scan after downtime can
                // tell what actually changed while the app was not running.
                t.column("contentModifiedAt", .datetime)
                t.column("fileSize", .integer)
                // Local only: inodes differ between machines even for the same file.
                t.column("inode", .integer)
            }
            try db.create(index: "node_path", on: "node", columns: ["projectID", "relativePath"], unique: true)
            try db.create(index: "node_parent", on: "node", columns: ["projectID", "parentPath"])
            try db.create(index: "node_search", on: "node", columns: ["searchName"])

            /// Two machines can mint different ids for one file if a rename happens
            /// before the second machine ever indexed it. Both sides then resolve to
            /// the same winner and keep the loser as a redirect, so old references
            /// in already-written logs keep working.
            try db.create(table: "nodeAlias") { t in
                t.primaryKey("loser", .text)
                t.column("winner", .text).notNull()
            }

            try db.create(table: "category") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("sortIndex", .integer).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "entry") { t in
                t.primaryKey("id", .text)
                t.column("projectID", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("nodeID", .text)
                t.column("authorID", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("observedAt", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("searchText", .text).notNull()
                t.column("isTask", .boolean).notNull().defaults(to: false)
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("assigneeID", .text)
                t.column("replyToID", .text)
                t.column("eventType", .text)
                t.column("eventCount", .integer)
                t.column("linesAdded", .integer)
                t.column("linesRemoved", .integer)
                t.column("fromPath", .text)
                t.column("isBackfilled", .boolean).notNull().defaults(to: false)
                t.column("dedupKey", .text)
                t.column("isSuperseded", .boolean).notNull().defaults(to: false)
                t.column("isRetracted", .boolean).notNull().defaults(to: false)
                t.column("patchedAt", .datetime)
            }
            try db.create(index: "entry_project_time", on: "entry", columns: ["projectID", "createdAt"])
            try db.create(index: "entry_node_time", on: "entry", columns: ["nodeID", "createdAt"])
            try db.create(index: "entry_dedup", on: "entry", columns: ["dedupKey"])
            try db.create(index: "entry_open_tasks", on: "entry", columns: ["isTask", "isDone"])

            try db.create(table: "entryCategory") { t in
                t.column("entryID", .text).notNull()
                    .references("entry", onDelete: .cascade)
                t.column("categoryID", .text).notNull()
                t.primaryKey(["entryID", "categoryID"])
            }

            /// Read state stays on the machine of the person it belongs to. An entry
            /// counts as read when it was actually on screen, not when its project
            /// was clicked.
            try db.create(table: "readState") { t in
                t.column("entryID", .text).notNull()
                    .references("entry", onDelete: .cascade)
                t.column("memberID", .text).notNull()
                t.column("readAt", .datetime).notNull()
                t.primaryKey(["entryID", "memberID"])
            }

            try db.create(table: "localSetting") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
        }

        // Ticking a task off and rewriting what somebody said are not the same
        // event, and only the second one is worth telling the reader about.
        m.registerMigration("v3-text-edits") { db in
            try db.alter(table: "entry") { t in
                t.add(column: "textEditedAt", .datetime)
            }
        }

        // Folders used to be indexed with the trailing slash that URL.path adds to
        // a directory, so they never matched the parent path their own files were
        // stored under and appeared empty.
        m.registerMigration("v2-normalise-folder-paths") { db in
            try db.execute(sql: """
                UPDATE node SET relativePath = rtrim(relativePath, '/')
                 WHERE relativePath LIKE '%/'
                """)
            try db.execute(sql: """
                UPDATE node SET parentPath = rtrim(parentPath, '/')
                 WHERE parentPath LIKE '%/'
                """)
        }

        // Node ids are derived from the relative path alone, which two projects can
        // share: every client folder has a Briefing.pdf. Ids are salted apart at
        // the point they are minted now, but a peer that only has one of those
        // projects still writes the unsalted id into its log, so a redirect has to
        // be able to mean different things in different projects.
        m.registerMigration("v4-alias-per-project") { db in
            try db.create(table: "nodeAliasScoped") { t in
                t.column("projectID", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("loser", .text).notNull()
                t.column("winner", .text).notNull()
                t.primaryKey(["projectID", "loser"])
            }
            // The project of an existing redirect is the project its winner is in.
            // A redirect whose winner is gone points at nothing and is dropped.
            try db.execute(sql: """
                INSERT OR IGNORE INTO nodeAliasScoped (projectID, loser, winner)
                SELECT n.projectID, a.loser, a.winner
                  FROM nodeAlias a JOIN node n ON n.id = a.winner
                """)
            try db.drop(table: "nodeAlias")
            try db.rename(table: "nodeAliasScoped", to: "nodeAlias")
        }

        // A system entry that is about the project rather than about a file:
        // somebody joined. Null everywhere it was written before, which is what a
        // system entry about a file keeps meaning.
        m.registerMigration("v5-entry-notice") { db in
            try db.alter(table: "entry") { t in
                t.add(column: "notice", .text)
            }
        }

        // Node ids a peer registered for files inside a document package, from
        // before packages were one document. Remembered so that the entries it
        // wrote about them can be recognised and left out, instead of each one
        // conjuring a placeholder file out of an id nobody can resolve.
        m.registerMigration("v6-package-interiors") { db in
            try db.create(table: "packageInterior") { t in
                t.column("projectID", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("nodeID", .text).notNull()
                t.column("packagePath", .text).notNull()
                t.primaryKey(["projectID", "nodeID"])
            }
        }

        return m
    }
}

/// Case- and accent-insensitive form used for every search column, so that
/// "Grussformel" finds "Grußformel" and "plakat" finds "Sommerplakat_v3".
public func searchNormalized(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                 locale: Locale(identifier: "en_US_POSIX"))
}
