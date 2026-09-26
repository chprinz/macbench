import Foundation
import GRDB

public enum TimelineScope: Sendable, Hashable {
    case project(UUID)
    /// A folder and everything inside it.
    case folder(UUID)
    case file(UUID)
    /// Everything that has happened, across all projects, newest last. Not
    /// narrowed to what is unread: a list that empties itself as you read it
    /// cannot be looked back at, and "unread" is the wrong promise anyway — most
    /// of what lands here is a file moving, not a message to anybody. What has
    /// not been read yet is marked inside the list instead.
    case activity
    /// Every open task, across all projects.
    case openTasks
}

public enum StatusFilter: String, Sendable, CaseIterable {
    case all
    case openTasks
    case doneTasks
}

/// Who a task is for. Only meaningful once the status filter is on tasks: an
/// ordinary message has no assignee, so filtering everything by person would
/// simply empty the stream.
public enum AssigneeFilter: Sendable, Hashable {
    case anyone
    case member(UUID)
    case unassigned
}

public struct TimelineFilter: Sendable, Hashable {
    public var categories: Set<UUID> = []
    public var status: StatusFilter = .all
    public var assignee: AssigneeFilter = .anyone
    /// One project out of the lists that span all of them. Nil is every project.
    public var project: UUID?
    /// When false, only what people wrote is shown.
    public var includeSystem: Bool = true
    public var searchText: String = ""
    public var limit: Int = 400

    public init() {}

    /// What the task list starts from: the tasks nobody has ticked off.
    public static var tasks: TimelineFilter {
        var filter = TimelineFilter()
        filter.status = .openTasks
        return filter
    }
}

public struct TimelineItem: Sendable, Hashable, Identifiable {
    public var entry: Entry
    public var categories: [Category]
    public var author: Member?
    public var assignee: Member?
    public var node: Node?
    public var isUnread: Bool
    public var id: UUID { entry.id }
}

public struct FileListItem: Sendable, Hashable, Identifiable {
    public var node: Node
    public var lastActivityAt: Date?
    public var lastAuthor: Member?
    public var unreadCount: Int
    public var openTaskCount: Int
    public var id: UUID { node.id }
}

/// Where the unread and open-task dots belong. Paths, not counts per folder: the
/// tree aggregates them itself, which keeps a deep structure to one query.
///
/// Each path is the folder the entry belongs in, not the node it is about: the
/// folder holding a file, or the folder itself when somebody wrote about a
/// folder. Given the folder's own path, the tree could not tell it from a file
/// of that name and put the dot one level up, on the folder around it.
public struct ActivitySignals: Sendable, Hashable {
    public var unreadFolders: [UUID: [String]] = [:]
    public var openTaskFolders: [UUID: [String]] = [:]
    public var unreadTotal: Int = 0
    public var openTaskTotal: Int = 0
    public init() {}
}

public struct SearchResults: Sendable {
    public var nodes: [Node] = []
    public var entries: [TimelineItem] = []
    public init() {}
    public var isEmpty: Bool { nodes.isEmpty && entries.isEmpty }
}

/// Per-person, per-project loudness, in one spelling because three queries have
/// to agree on it: the stream, the dots in the tree, and the unread count on a
/// file row. It is kept out of the log on purpose — one person muting a project
/// must not mute it for anyone else.
///
/// A notice is as loud as a message: somebody joining is not a file change,
/// happens once, and cannot be folded into a quieter line.
/// The folder an entry's dot belongs in: see `ActivitySignals`. The project
/// itself, where the entry is about no file at all.
let homeFolder = """
    CASE WHEN n.id IS NULL THEN ''
         WHEN n.isDirectory = 1 THEN n.relativePath
         ELSE n.parentPath END
    """

let loudEnoughToShow = """
    (e.kind = 'message'
     OR e.notice IS NOT NULL
     OR p.verbosity = 'everything'
     OR (p.verbosity = 'majorOnly' AND e.eventType IN ('created','removed','moved','renamed')))
    """

extension Store {

    // MARK: - Timeline

    public func timeline(scope: TimelineScope, filter: TimelineFilter = TimelineFilter(),
                         viewer: UUID) throws -> [TimelineItem] {
        try read { db in
            var conditions: [String] = ["e.isSuperseded = 0", "e.isRetracted = 0"]
            // Twice: once for "is it mine", once for the read-state join.
            var args: [any DatabaseValueConvertible] = [viewer, viewer]

            switch scope {
            case .project(let id):
                conditions.append("e.projectID = ?")
                args.append(id)
            case .folder(let nodeID):
                guard let node = try Store.resolveNode(id: nodeID, in: db) else { return [] }
                conditions.append("""
                    (e.nodeID = ? OR e.nodeID IN (
                        SELECT id FROM node WHERE projectID = ? AND relativePath >= ? AND relativePath < ?))
                    """)
                args.append(contentsOf: [node.id, node.projectID,
                                         node.relativePath + "/", node.relativePath + "0"])
            case .file(let nodeID):
                guard let node = try Store.resolveNode(id: nodeID, in: db) else { return [] }
                conditions.append("e.nodeID = ?")
                args.append(node.id)
            case .activity:
                // Every project, everything in it, your own entries included —
                // "what has happened" is not a question about somebody else. Only
                // a project put away is left out: that is what putting it away is.
                conditions.append("p.isArchived = 0")
            case .openTasks:
                // The task list is a scope, not a status. Pinning it to the open
                // ones here as well made "Done" a filter that could only ever come
                // back empty — the one place people go looking for what they have
                // just ticked off.
                conditions.append("e.isTask = 1 AND p.isArchived = 0")
                if filter.status != .doneTasks { conditions.append("e.isDone = 0") }
            }

            conditions.append(loudEnoughToShow)

            if let project = filter.project {
                conditions.append("e.projectID = ?")
                args.append(project)
            }

            if !filter.includeSystem { conditions.append("e.kind = 'message'") }
            switch filter.status {
            case .all: break
            case .openTasks: conditions.append("e.isTask = 1 AND e.isDone = 0")
            case .doneTasks: conditions.append("e.isTask = 1 AND e.isDone = 1")
            }
            switch filter.assignee {
            case .anyone: break
            case .unassigned: conditions.append("e.assigneeID IS NULL")
            case .member(let id):
                conditions.append("e.assigneeID = ?")
                args.append(id)
            }
            if !filter.categories.isEmpty {
                let placeholders = filter.categories.map { _ in "?" }.joined(separator: ",")
                conditions.append("e.id IN (SELECT entryID FROM entryCategory WHERE categoryID IN (\(placeholders)))")
                args.append(contentsOf: filter.categories.map { $0 as any DatabaseValueConvertible })
            }
            let needle = searchNormalized(filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines))
            if !needle.isEmpty {
                conditions.append("(e.searchText LIKE ? ESCAPE '\\' OR n.searchName LIKE ? ESCAPE '\\')")
                let pattern = "%" + likeEscaped(needle) + "%"
                args.append(contentsOf: [pattern, pattern])
            }

            let sql = """
                -- What you wrote yourself is never unread to you. The dots in the
                -- tree and the counts in the file lists have always taken that
                -- view; the stream used to draw a blue bar beside your own
                -- sentence until you scrolled past it.
                SELECT e.*,
                       (rs.entryID IS NULL AND (e.authorID IS NULL OR e.authorID <> ?)) AS unread
                FROM entry e
                JOIN project p ON p.id = e.projectID
                LEFT JOIN node n ON n.id = e.nodeID
                LEFT JOIN readState rs ON rs.entryID = e.id AND rs.memberID = ?
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY e.createdAt DESC, e.id DESC
                LIMIT \(max(1, filter.limit))
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            let items = try Store.hydrate(rows: rows, viewer: viewer, in: db)
            return items.reversed()
        }
    }

    static func hydrate(rows: [Row], viewer: UUID, in db: Database) throws -> [TimelineItem] {
        guard !rows.isEmpty else { return [] }
        // A row that cannot be decoded is one entry, not the whole window: a
        // column added by a newer version, or a value written by a version that
        // reads this table differently, must not take the stream down with it.
        let entries = rows.compactMap { row -> (Entry, Bool)? in
            guard let entryRow = try? EntryRow(row: row) else { return nil }
            let unread = (row["unread"] as Bool?) ?? false
            return (entryRow.entry, unread)
        }
        guard !entries.isEmpty else { return [] }

        let entryIDs = entries.map(\.0.id)
        var categoriesByEntry: [UUID: [Category]] = [:]
        let allCategories = try CategoryRow.fetchAll(db).reduce(into: [UUID: Category]()) {
            $0[$1.id] = $1.category
        }
        let links = try Row.fetchAll(db, sql: """
            SELECT entryID, categoryID FROM entryCategory WHERE entryID IN (\(placeholders(entryIDs.count)))
            """, arguments: StatementArguments(entryIDs.map { $0 as any DatabaseValueConvertible }))
        for link in links {
            guard let entryID: UUID = link["entryID"], let categoryID: UUID = link["categoryID"],
                  let category = allCategories[categoryID] else { continue }
            categoriesByEntry[entryID, default: []].append(category)
        }

        let memberIDs = Set(entries.flatMap { [$0.0.authorID, $0.0.assigneeID].compactMap { $0 } })
        let members = try MemberRow.filter(keys: memberIDs).fetchAll(db)
            .reduce(into: [UUID: Member]()) { $0[$1.id] = $1.member }

        let nodeIDs = Set(entries.compactMap(\.0.nodeID))
        let nodes = try NodeRow.filter(keys: nodeIDs).fetchAll(db)
            .reduce(into: [UUID: Node]()) { $0[$1.id] = $1.node }

        return entries.map { entry, unread in
            var item = TimelineItem(
                entry: entry,
                categories: (categoriesByEntry[entry.id] ?? []).sorted { $0.sortIndex < $1.sortIndex },
                author: entry.authorID.flatMap { members[$0] },
                assignee: entry.assigneeID.flatMap { members[$0] },
                node: entry.nodeID.flatMap { nodes[$0] },
                isUnread: unread)
            // You have read what you wrote.
            if entry.authorID == viewer { item.isUnread = false }
            item.entry.categoryIDs = Set(item.categories.map(\.id))
            return item
        }
    }

    // MARK: - Tree and file list

    public func folders(projectID: UUID, parentPath: String) throws -> [Node] {
        try read { db in
            try NodeRow
                .filter(Column("projectID") == projectID)
                .filter(Column("parentPath") == parentPath)
                .filter(Column("isDirectory") == true)
                .filter(Column("state") == NodeState.present.rawValue)
                .order(Column("name").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db).map(\.node)
        }
    }

    public func files(projectID: UUID, parentPath: String, viewer: UUID,
                      includeDeleted: Bool = false) throws -> [FileListItem] {
        try read { db in
            let states = includeDeleted
                ? [NodeState.present.rawValue, NodeState.deleted.rawValue]
                : [NodeState.present.rawValue]
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.*,
                       (SELECT MAX(createdAt) FROM entry e
                         WHERE e.nodeID = n.id AND e.isSuperseded = 0 AND e.isRetracted = 0) AS lastAt,
                       -- Not a withdrawn message's author: the time beside the
                       -- name already leaves those out, and the two disagreed.
                       (SELECT m.id FROM entry e JOIN member m ON m.id = e.authorID
                         WHERE e.nodeID = n.id AND e.isSuperseded = 0 AND e.isRetracted = 0
                         ORDER BY e.createdAt DESC LIMIT 1) AS lastAuthorID,
                       (SELECT m.name FROM entry e JOIN member m ON m.id = e.authorID
                         WHERE e.nodeID = n.id AND e.isSuperseded = 0 AND e.isRetracted = 0
                         ORDER BY e.createdAt DESC LIMIT 1) AS lastAuthorName,
                       (SELECT m.colorHex FROM entry e JOIN member m ON m.id = e.authorID
                         WHERE e.nodeID = n.id AND e.isSuperseded = 0 AND e.isRetracted = 0
                         ORDER BY e.createdAt DESC LIMIT 1) AS lastAuthorColor,
                       -- The same loudness rule as the stream and the tree, from the
                       -- same string. Without it a muted project shows a dot on a file
                       -- whose change is not in the stream, so reading it is not
                       -- possible and the dot stays.
                       (SELECT COUNT(*) FROM entry e
                          LEFT JOIN readState rs ON rs.entryID = e.id AND rs.memberID = ?
                         WHERE e.nodeID = n.id AND rs.entryID IS NULL AND e.isSuperseded = 0
                           AND e.isRetracted = 0 AND (e.authorID IS NULL OR e.authorID <> ?)
                           AND \(loudEnoughToShow)) AS unread,
                       (SELECT COUNT(*) FROM entry e
                         WHERE e.nodeID = n.id AND e.isTask = 1 AND e.isDone = 0
                           AND e.isSuperseded = 0 AND e.isRetracted = 0) AS openTasks
                FROM node n
                JOIN project p ON p.id = n.projectID
                WHERE n.projectID = ? AND n.parentPath = ? AND n.isDirectory = 0
                  AND n.state IN (\(placeholders(states.count)))
                ORDER BY n.name COLLATE NOCASE
                """, arguments: StatementArguments(
                    [viewer, viewer, projectID, parentPath] as [any DatabaseValueConvertible]
                    + states.map { $0 as any DatabaseValueConvertible }))

            return try rows.map { row in
                let node = try NodeRow(row: row).node
                let lastAt: Date? = row["lastAt"]
                var author: Member?
                if let id: UUID = row["lastAuthorID"], let name: String = row["lastAuthorName"] {
                    author = Member(id: id, name: name, colorHex: row["lastAuthorColor"] ?? "#888888")
                }
                return FileListItem(node: node, lastActivityAt: lastAt, lastAuthor: author,
                                    unreadCount: row["unread"] ?? 0,
                                    openTaskCount: row["openTasks"] ?? 0)
            }
        }
    }

    // MARK: - Dots in the tree

    public func activitySignals(viewer: UUID) throws -> ActivitySignals {
        try read { db in
            var signals = ActivitySignals()
            let unread = try Row.fetchAll(db, sql: """
                SELECT e.projectID AS pid, \(homeFolder) AS path
                FROM entry e
                JOIN project p ON p.id = e.projectID AND p.isArchived = 0
                LEFT JOIN node n ON n.id = e.nodeID
                LEFT JOIN readState rs ON rs.entryID = e.id AND rs.memberID = ?
                WHERE rs.entryID IS NULL AND e.isSuperseded = 0 AND e.isRetracted = 0
                  AND (e.authorID IS NULL OR e.authorID <> ?)
                  AND \(loudEnoughToShow)
                """, arguments: [viewer, viewer])
            for row in unread {
                guard let pid: UUID = row["pid"] else { continue }
                signals.unreadFolders[pid, default: []].append(row["path"] ?? "")
                signals.unreadTotal += 1
            }

            let tasks = try Row.fetchAll(db, sql: """
                SELECT e.projectID AS pid, \(homeFolder) AS path
                FROM entry e
                JOIN project p ON p.id = e.projectID AND p.isArchived = 0
                LEFT JOIN node n ON n.id = e.nodeID
                WHERE e.isTask = 1 AND e.isDone = 0 AND e.isSuperseded = 0 AND e.isRetracted = 0
                """)
            for row in tasks {
                guard let pid: UUID = row["pid"] else { continue }
                signals.openTaskFolders[pid, default: []].append(row["path"] ?? "")
                signals.openTaskTotal += 1
            }
            return signals
        }
    }

    // MARK: - What deserves an interruption

    /// The only things allowed to raise a notification: something a person wrote,
    /// addressed to you. A task with your name on it, or a reply to something you
    /// said. File changes never qualify, no matter how many there are — an app
    /// that pings for those gets muted within a week and then it is useless.
    public func entriesDeservingNotification(since: Date, viewer: UUID) throws -> [TimelineItem] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.*, 1 AS unread
                FROM entry e
                LEFT JOIN readState rs ON rs.entryID = e.id AND rs.memberID = ?
                WHERE e.kind = 'message'
                  AND e.isSuperseded = 0 AND e.isRetracted = 0
                  AND e.observedAt > ?
                  AND e.authorID IS NOT NULL AND e.authorID <> ?
                  AND rs.entryID IS NULL
                  AND (e.assigneeID = ?
                       OR e.replyToID IN (SELECT id FROM entry WHERE authorID = ?))
                ORDER BY e.createdAt
                """, arguments: [viewer, since, viewer, viewer, viewer])
            return try Store.hydrate(rows: rows, viewer: viewer, in: db)
        }
    }

    // MARK: - Search

    /// Searches file names, folder names and everything anyone ever wrote. This is
    /// the point of the app: a file becomes findable because somebody said
    /// something about it.
    public func search(_ text: String, viewer: UUID, limit: Int = 60) throws -> SearchResults {
        let needle = searchNormalized(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard needle.count >= 2 else { return SearchResults() }
        let pattern = "%" + likeEscaped(needle) + "%"

        var results = SearchResults()
        results.nodes = try read { db in
            try NodeRow
                .filter(sql: """
                    searchName LIKE ? ESCAPE '\\' AND state <> ? AND relativePath NOT LIKE ?
                    """,
                        arguments: [pattern, NodeState.archived.rawValue,
                                    Node.placeholderPrefix + "/%"])
                // Files that are still there first. Ordering by the column itself
                // put deleted above present, because "deleted" happens to sort
                // before "present" — which is a property of the spelling, not
                // something anyone decided.
                .order(sql: "(state = ?) DESC, lastSeenAt DESC",
                       arguments: [NodeState.present.rawValue])
                .limit(limit)
                .fetchAll(db).map(\.node)
        }
        var filter = TimelineFilter()
        filter.searchText = text
        filter.limit = limit
        results.entries = try read { db in
            let sql = """
                SELECT e.*,
                       (rs.entryID IS NULL AND (e.authorID IS NULL OR e.authorID <> ?)) AS unread
                FROM entry e
                LEFT JOIN node n ON n.id = e.nodeID
                LEFT JOIN readState rs ON rs.entryID = e.id AND rs.memberID = ?
                WHERE e.isSuperseded = 0 AND e.isRetracted = 0
                  AND (e.searchText LIKE ? ESCAPE '\\' OR n.searchName LIKE ? ESCAPE '\\')
                ORDER BY e.createdAt DESC LIMIT \(limit)
                """
            let rows = try Row.fetchAll(db, sql: sql,
                                        arguments: [viewer, viewer, pattern, pattern])
            return try Store.hydrate(rows: rows, viewer: viewer, in: db)
        }
        return results
    }
}

func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: max(count, 1)).joined(separator: ",")
}

/// LIKE treats % and _ as wildcards; a search for "50 %" must not match everything.
func likeEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
}
