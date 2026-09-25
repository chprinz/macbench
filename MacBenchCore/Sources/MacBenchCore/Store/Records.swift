import Foundation
import GRDB

struct MemberRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "member"
    var id: UUID
    var name: String
    var colorHex: String
    var updatedAt: Date

    init(_ member: Member, updatedAt: Date) {
        id = member.id; name = member.name; colorHex = member.colorHex; self.updatedAt = updatedAt
    }
    var member: Member { Member(id: id, name: name, colorHex: colorHex) }
}

struct CategoryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "category"
    var id: UUID
    var name: String
    var colorHex: String
    var sortIndex: Int
    var isDeleted: Bool
    var isBuiltIn: Bool

    init(_ c: Category) {
        id = c.id; name = c.name; colorHex = c.colorHex
        sortIndex = c.sortIndex; isDeleted = c.isDeleted; isBuiltIn = c.isBuiltIn
    }
    var category: Category {
        Category(id: id, name: name, colorHex: colorHex, sortIndex: sortIndex, isDeleted: isDeleted)
    }
}

struct NodeRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "node"
    var id: UUID
    var projectID: UUID
    var relativePath: String
    var parentPath: String
    var name: String
    var searchName: String
    var isDirectory: Bool
    var state: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var contentModifiedAt: Date?
    var fileSize: Int64?
    var inode: Int64?

    init(_ node: Node, inode: Int64? = nil) {
        id = node.id
        projectID = node.projectID
        relativePath = node.relativePath
        parentPath = node.parentPath ?? ""
        name = node.name
        searchName = searchNormalized(node.name)
        isDirectory = node.isDirectory
        state = node.state.rawValue
        firstSeenAt = node.firstSeenAt
        lastSeenAt = node.lastSeenAt
        contentModifiedAt = node.contentModifiedAt
        fileSize = node.fileSize
        self.inode = inode
    }

    var node: Node {
        var node = Node(id: id, projectID: projectID, relativePath: relativePath,
                        isDirectory: isDirectory, state: NodeState(rawValue: state) ?? .present,
                        firstSeenAt: firstSeenAt, lastSeenAt: lastSeenAt)
        node.contentModifiedAt = contentModifiedAt
        node.fileSize = fileSize
        return node
    }
}

struct ProjectRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project"
    var id: UUID
    var name: String
    var isArchived: Bool
    var addedAt: Date
    var sortIndex: Int
    var rootPath: String?
    var rootBookmark: Data?
    var verbosity: String
    var lastFSEventID: Int64?
    var lastScanAt: Date?
    var excludedPaths: String

    var project: Project {
        Project(id: id, name: name, isArchived: isArchived, addedAt: addedAt)
    }
    var excluded: Set<String> {
        (try? JSONDecoder().decode([String].self, from: Data(excludedPaths.utf8))).map(Set.init) ?? []
    }
}

struct EntryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entry"
    var id: UUID
    var projectID: UUID
    var nodeID: UUID?
    var authorID: UUID?
    var createdAt: Date
    var observedAt: Date
    var kind: String
    var text: String
    var searchText: String
    var isTask: Bool
    var isDone: Bool
    var assigneeID: UUID?
    var replyToID: UUID?
    var eventType: String?
    var eventCount: Int?
    var linesAdded: Int?
    var linesRemoved: Int?
    var fromPath: String?
    var isBackfilled: Bool
    var notice: String?
    var dedupKey: String?
    var isSuperseded: Bool
    var isRetracted: Bool
    var patchedAt: Date?
    var textEditedAt: Date?

    init(_ entry: Entry, patchedAt: Date? = nil) {
        id = entry.id
        projectID = entry.projectID
        nodeID = entry.nodeID
        authorID = entry.authorID
        createdAt = entry.createdAt
        observedAt = entry.observedAt
        kind = entry.kind.rawValue
        text = entry.text
        searchText = searchNormalized(entry.text)
        isTask = entry.isTask
        isDone = entry.isDone
        assigneeID = entry.assigneeID
        replyToID = entry.replyToID
        eventType = entry.event?.type.rawValue
        eventCount = entry.event?.count
        linesAdded = entry.event?.linesAdded
        linesRemoved = entry.event?.linesRemoved
        fromPath = entry.event?.fromPath
        isBackfilled = entry.event?.backfilled ?? false
        notice = entry.notice?.rawValue
        dedupKey = entry.dedupKey
        isSuperseded = entry.isSuperseded
        isRetracted = false
        self.patchedAt = patchedAt
        textEditedAt = entry.textEditedAt
    }

    var entry: Entry {
        var event: FileEvent?
        if let eventType, let type = FileEventType(rawValue: eventType) {
            event = FileEvent(type: type, count: eventCount ?? 1, linesAdded: linesAdded,
                              linesRemoved: linesRemoved, fromPath: fromPath, backfilled: isBackfilled)
        }
        return Entry(id: id, projectID: projectID, nodeID: nodeID, authorID: authorID,
                     createdAt: createdAt, observedAt: observedAt,
                     kind: EntryKind(rawValue: kind) ?? .message, text: text,
                     isTask: isTask, isDone: isDone, assigneeID: assigneeID, replyToID: replyToID,
                     categoryIDs: [], event: event,
                     notice: notice.flatMap(Notice.init(rawValue:)), dedupKey: dedupKey,
                     isSuperseded: isSuperseded, textEditedAt: textEditedAt)
    }
}

struct EntryCategoryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entryCategory"
    var entryID: UUID
    var categoryID: UUID
}

struct ReadStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "readState"
    var entryID: UUID
    var memberID: UUID
    var readAt: Date
}

struct PeerRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projectPeer"
    var projectID: UUID
    var deviceID: UUID
    var memberID: UUID?
    var deviceName: String?
    var lastSequence: Int
    var claimedSequence: Int
    var lastReadAt: Date?
}
