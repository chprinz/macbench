import Foundation

// MARK: - Member

/// A person. Not an account: there is no server and no login. A member id is
/// minted once per person and travels in the log, so both machines agree on who
/// said what. One person using two Macs joins with the same member id.
public struct Member: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Stored as hex so the log stays readable and independent of any colour space.
    public var colorHex: String

    public init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

// MARK: - Node

public enum NodeState: String, Codable, Sendable, CaseIterable {
    case present
    case deleted
    case archived
}

/// A file or a folder. The id is derived from the path it was first seen at and
/// never changes again; renames and moves rewrite `relativePath` only, which is
/// what keeps a file's history attached to it across a reorganisation.
public struct Node: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    /// Relative to the project root. Absolute paths never leave the local machine:
    /// they contain the user's account name and mean nothing on the other Mac.
    public var relativePath: String
    public var name: String
    public var isDirectory: Bool
    public var state: NodeState
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    /// The file's own modification date and size as last indexed. A catch-up scan
    /// compares against these to find what happened while the app was closed.
    public var contentModifiedAt: Date?
    public var fileSize: Int64?

    public init(id: UUID, projectID: UUID, relativePath: String, isDirectory: Bool,
                state: NodeState = .present, firstSeenAt: Date, lastSeenAt: Date) {
        self.id = id
        self.projectID = projectID
        self.relativePath = relativePath
        self.name = (relativePath as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.state = state
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    /// A stand-in for a file an entry refers to but whose registration has not
    /// arrived yet. It holds the entry's place instead of orphaning it.
    public static let placeholderPrefix = "?"
    public var isPlaceholder: Bool { relativePath.hasPrefix(Node.placeholderPrefix) }

    public static func placeholderPath(for id: UUID) -> String {
        "\(placeholderPrefix)/\(id.uuidString)"
    }

    public var parentPath: String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }
}

// MARK: - Category

public struct Category: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var sortIndex: Int
    public var isDeleted: Bool

    public init(id: UUID = UUID(), name: String, colorHex: String, sortIndex: Int, isDeleted: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortIndex = sortIndex
        self.isDeleted = isDeleted
    }

    /// Shipped defaults. Ids are derived from the slug, not random, so both
    /// machines create the same four and not eight.
    public static let builtIns: [Category] = [
        Category(id: Namespace.builtInCategoryID(slug: "feedback"), name: "feedback", colorHex: "#E4572E", sortIndex: 0),
        Category(id: Namespace.builtInCategoryID(slug: "technical"), name: "technical", colorHex: "#2E86AB", sortIndex: 1),
        Category(id: Namespace.builtInCategoryID(slug: "admin"), name: "admin", colorHex: "#8367C7", sortIndex: 2),
        Category(id: Namespace.builtInCategoryID(slug: "system"), name: "system", colorHex: "#6B7280", sortIndex: 3),
    ]

    /// Localisation key for the shipped ones; user-created categories keep their literal name.
    public var isBuiltIn: Bool {
        Category.builtIns.contains { $0.id == id }
    }
}

// MARK: - Events

public enum FileEventType: String, Codable, Sendable, CaseIterable {
    case created
    case modified
    case renamed
    case moved
    case removed

    /// Loudness, per the spec: created / removed / moved always show, renamed is
    /// middling, modified is quiet and gets folded away.
    public var loudness: Loudness {
        switch self {
        case .created, .removed, .moved: .loud
        case .renamed: .medium
        case .modified: .quiet
        }
    }
}

public enum Loudness: Int, Codable, Sendable, Comparable {
    case quiet = 0
    case medium = 1
    case loud = 2
    public static func < (a: Loudness, b: Loudness) -> Bool { a.rawValue < b.rawValue }
}

/// The payload of a system entry.
public struct FileEvent: Codable, Hashable, Sendable {
    public var type: FileEventType
    /// How many raw filesystem events were folded into this one entry.
    public var count: Int
    public var linesAdded: Int?
    public var linesRemoved: Int?
    /// Path a rename or move came from, so the entry can say what it used to be called.
    public var fromPath: String?
    /// True when the entry was reconstructed by a catch-up scan rather than
    /// observed live. Its timestamp is then approximate and the UI says so.
    public var backfilled: Bool

    public init(type: FileEventType, count: Int = 1, linesAdded: Int? = nil, linesRemoved: Int? = nil,
                fromPath: String? = nil, backfilled: Bool = false) {
        self.type = type
        self.count = count
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.fromPath = fromPath
        self.backfilled = backfilled
    }
}

// MARK: - Entry

public enum EntryKind: String, Codable, Sendable {
    case message
    case system
}

/// What a system entry is about when it is not a file change.
///
/// Structured rather than a sentence: the log travels between machines, and a
/// sentence would arrive in the language of whoever wrote it. The reader builds
/// the words in its own.
public enum Notice: String, Codable, Sendable {
    /// Somebody added this project folder for the first time.
    case joined
}

/// The one structure the whole app is built on. A chat line, a task, a comment on
/// a file and a "this file changed" notice are the same record with different
/// fields filled in.
public struct Entry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var nodeID: UUID?
    /// `nil` means: we know something changed, but not yet who did it. This happens
    /// when a change arrives through file sync while the author's app was closed.
    /// The entry heals into the right author when their log catches up.
    public var authorID: UUID?
    /// When the change actually happened, derived from the file's modification date
    /// — never when the event reached this machine. Sync can be hours behind.
    public var createdAt: Date
    /// When this machine learned about it. Local only, used to break authorship ties.
    public var observedAt: Date
    public var kind: EntryKind
    public var text: String
    public var isTask: Bool
    public var isDone: Bool
    public var assigneeID: UUID?
    public var replyToID: UUID?
    public var categoryIDs: Set<UUID>
    public var event: FileEvent?
    /// Set on a system entry that is about the project rather than about a file.
    public var notice: Notice?
    /// Business key for de-duplication: node + event type + 20-minute bucket.
    /// Two machines that both witness one change produce the same key.
    public var dedupKey: String?
    /// A system entry that lost the authorship race and is kept only for repair.
    public var isSuperseded: Bool
    /// When the wording was last changed, if it ever was. Shown to the reader:
    /// quietly rewriting what somebody read yesterday is not something to hide.
    public var textEditedAt: Date?

    public init(id: UUID = UUID(), projectID: UUID, nodeID: UUID? = nil, authorID: UUID?,
                createdAt: Date, observedAt: Date, kind: EntryKind, text: String,
                isTask: Bool = false, isDone: Bool = false, assigneeID: UUID? = nil,
                replyToID: UUID? = nil, categoryIDs: Set<UUID> = [], event: FileEvent? = nil,
                notice: Notice? = nil, dedupKey: String? = nil, isSuperseded: Bool = false,
                textEditedAt: Date? = nil) {
        self.id = id
        self.projectID = projectID
        self.nodeID = nodeID
        self.authorID = authorID
        self.createdAt = createdAt
        self.observedAt = observedAt
        self.kind = kind
        self.text = text
        self.isTask = isTask
        self.isDone = isDone
        self.assigneeID = assigneeID
        self.replyToID = replyToID
        self.categoryIDs = categoryIDs
        self.event = event
        self.notice = notice
        self.dedupKey = dedupKey
        self.isSuperseded = isSuperseded
        self.textEditedAt = textEditedAt
    }

    public var isOpenTask: Bool { isTask && !isDone }
}

// MARK: - Dedup key

public enum DedupKey {
    /// Twenty minutes, matching the coalescing window: everything one machine folds
    /// into a single entry maps onto exactly one bucket on the other machine too.
    public static let bucket: TimeInterval = 20 * 60

    public static func make(nodeID: UUID, event: FileEventType, at date: Date) -> String {
        let slot = Int((date.timeIntervalSince1970 / bucket).rounded(.down))
        return "\(nodeID.uuidString):\(event.rawValue):\(slot)"
    }

    /// Joining has no bucket: it happens once. Somebody's second Mac reports the
    /// same fact rather than a second one, and the earlier of the two survives.
    public static func joined(memberID: UUID) -> String {
        "joined:\(memberID.uuidString)"
    }
}

// MARK: - Verbosity

/// How much of the change stream a person wants to see. Per person and per
/// project, and deliberately not shared: if one person mutes a project, everyone
/// else keeps seeing it.
public enum Verbosity: String, Codable, Sendable, CaseIterable {
    case everything
    case majorOnly
    case off

    /// The rule itself is applied in SQL, in `Store.timeline` and the two lists
    /// beside it, because it has to be part of the query that pages. Restating it
    /// here as a second, unused spelling is how the two drift apart.
}

// MARK: - Project

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isArchived: Bool
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, isArchived: Bool = false, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
        self.addedAt = addedAt
    }
}
