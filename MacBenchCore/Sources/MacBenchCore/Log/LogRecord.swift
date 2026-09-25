import Foundation

/// Bump only for changes a previous version cannot read. Readers skip records
/// from a newer major version instead of guessing, and say so in the UI.
public let logFormatVersion = 1

// MARK: - Bodies

public struct NodeRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var isDirectory: Bool
    public var firstSeenAt: Date
    public init(id: UUID, path: String, isDirectory: Bool, firstSeenAt: Date) {
        self.id = id; self.path = path; self.isDirectory = isDirectory; self.firstSeenAt = firstSeenAt
    }
}

public struct NodeRenameRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var from: String
    public var to: String
    public var at: Date
    /// Whether this is a folder. Optional because logs written before it existed
    /// do not have it, and a missing value has to keep meaning what it meant then.
    /// It matters on the receiving side: moving a folder moves everything under
    /// it, and a folder taken for a file leaves its contents behind at the old
    /// path. Additive, so it needs no format bump — an older reader ignores it.
    public var isDirectory: Bool?

    public init(id: UUID, from: String, to: String, at: Date, isDirectory: Bool? = nil) {
        self.id = id; self.from = from; self.to = to; self.at = at
        self.isDirectory = isDirectory
    }
}

public struct NodeStateRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var state: NodeState
    public var at: Date
    public init(id: UUID, state: NodeState, at: Date) {
        self.id = id; self.state = state; self.at = at
    }
}

/// Emitted when two machines independently minted ids for what turns out to be
/// the same node. Both sides resolve it the same way, so the record is a
/// confirmation rather than an instruction.
public struct NodeAliasRecord: Codable, Hashable, Sendable {
    public var loser: UUID
    public var winner: UUID
    public init(loser: UUID, winner: UUID) { self.loser = loser; self.winner = winner }
}

/// An entry as it travels. No project id: the log lives inside the project folder,
/// so the project is implied. That removes the last thing two machines would have
/// had to agree on before they can talk.
public struct EntryRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var nodeID: UUID?
    public var authorID: UUID?
    public var createdAt: Date
    public var kind: EntryKind
    public var text: String
    public var isTask: Bool
    public var isDone: Bool
    public var assigneeID: UUID?
    public var replyToID: UUID?
    public var categoryIDs: [UUID]
    public var event: FileEvent?
    /// Optional because logs written before it existed do not have it, and a
    /// missing value has to keep meaning what it meant then: a system entry about
    /// a file. Additive, so it needs no format bump — an older reader ignores it
    /// and falls back to `text`, which is why a notice carries a plain sentence
    /// there as well.
    public var notice: Notice?
    public var dedupKey: String?

    public init(entry: Entry) {
        id = entry.id
        nodeID = entry.nodeID
        authorID = entry.authorID
        createdAt = entry.createdAt
        kind = entry.kind
        text = entry.text
        isTask = entry.isTask
        isDone = entry.isDone
        assigneeID = entry.assigneeID
        replyToID = entry.replyToID
        categoryIDs = entry.categoryIDs.sorted { $0.uuidString < $1.uuidString }
        event = entry.event
        notice = entry.notice
        dedupKey = entry.dedupKey
    }

    public func entry(projectID: UUID, observedAt: Date) -> Entry {
        Entry(id: id, projectID: projectID, nodeID: nodeID, authorID: authorID,
              createdAt: createdAt, observedAt: observedAt, kind: kind, text: text,
              isTask: isTask, isDone: isDone, assigneeID: assigneeID, replyToID: replyToID,
              categoryIDs: Set(categoryIDs), event: event, notice: notice,
              dedupKey: dedupKey)
    }
}

/// Last-writer-wins per field, ordered by the envelope timestamp. Only fields
/// that are present were touched; the rest keep whatever they had.
public struct EntryPatchRecord: Codable, Hashable, Sendable {
    public var entryID: UUID
    public var text: String?
    public var isTask: Bool?
    public var isDone: Bool?
    public var assigneeID: UUID??
    public var replyToID: UUID??
    public var categoryIDs: [UUID]?
    public var isRetracted: Bool?

    public init(entryID: UUID, text: String? = nil, isTask: Bool? = nil, isDone: Bool? = nil,
                assigneeID: UUID?? = nil, replyToID: UUID?? = nil,
                categoryIDs: [UUID]? = nil, isRetracted: Bool? = nil) {
        self.entryID = entryID; self.text = text; self.isTask = isTask; self.isDone = isDone
        self.assigneeID = assigneeID; self.replyToID = replyToID
        self.categoryIDs = categoryIDs; self.isRetracted = isRetracted
    }
}

// MARK: - Envelope

public enum LogBody: Hashable, Sendable {
    case member(Member)
    case category(Category)
    case node(NodeRecord)
    case nodeRename(NodeRenameRecord)
    case nodeState(NodeStateRecord)
    case nodeAlias(NodeAliasRecord)
    case entry(EntryRecord)
    case entryPatch(EntryPatchRecord)

    var typeName: String {
        switch self {
        case .member: "member"
        case .category: "category"
        case .node: "node"
        case .nodeRename: "nodeRename"
        case .nodeState: "nodeState"
        case .nodeAlias: "nodeAlias"
        case .entry: "entry"
        case .entryPatch: "entryPatch"
        }
    }
}

public struct LogRecord: Hashable, Sendable {
    public var version: Int
    public var id: UUID
    /// Per-device, strictly increasing, no holes. A hole means a segment did not
    /// arrive — which the reader reports rather than papers over.
    public var sequence: Int
    public var deviceID: UUID
    public var writtenAt: Date
    public var body: LogBody

    public init(version: Int = logFormatVersion, id: UUID = UUID(), sequence: Int,
                deviceID: UUID, writtenAt: Date, body: LogBody) {
        self.version = version; self.id = id; self.sequence = sequence
        self.deviceID = deviceID; self.writtenAt = writtenAt; self.body = body
    }
}

extension LogRecord: Codable {
    private enum Keys: String, CodingKey {
        case v, id, seq, device, at, type, body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(Int.self, forKey: .v)
        id = try c.decode(UUID.self, forKey: .id)
        sequence = try c.decode(Int.self, forKey: .seq)
        deviceID = try c.decode(UUID.self, forKey: .device)
        writtenAt = try c.decode(Date.self, forKey: .at)
        let type = try c.decode(String.self, forKey: .type)
        body = switch type {
        case "member": .member(try c.decode(Member.self, forKey: .body))
        case "category": .category(try c.decode(Category.self, forKey: .body))
        case "node": .node(try c.decode(NodeRecord.self, forKey: .body))
        case "nodeRename": .nodeRename(try c.decode(NodeRenameRecord.self, forKey: .body))
        case "nodeState": .nodeState(try c.decode(NodeStateRecord.self, forKey: .body))
        case "nodeAlias": .nodeAlias(try c.decode(NodeAliasRecord.self, forKey: .body))
        case "entry": .entry(try c.decode(EntryRecord.self, forKey: .body))
        case "entryPatch": .entryPatch(try c.decode(EntryPatchRecord.self, forKey: .body))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: c.codingPath, debugDescription: "Unknown record type: \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(sequence, forKey: .seq)
        try c.encode(deviceID, forKey: .device)
        try c.encode(writtenAt, forKey: .at)
        try c.encode(body.typeName, forKey: .type)
        switch body {
        case .member(let x): try c.encode(x, forKey: .body)
        case .category(let x): try c.encode(x, forKey: .body)
        case .node(let x): try c.encode(x, forKey: .body)
        case .nodeRename(let x): try c.encode(x, forKey: .body)
        case .nodeState(let x): try c.encode(x, forKey: .body)
        case .nodeAlias(let x): try c.encode(x, forKey: .body)
        case .entry(let x): try c.encode(x, forKey: .body)
        case .entryPatch(let x): try c.encode(x, forKey: .body)
        }
    }
}

// MARK: - Manifest

/// A stretch of wall-clock time during which a device was running.
public struct AwakeWindow: Codable, Hashable, Sendable {
    public var from: Date
    public var to: Date
    public init(from: Date, to: Date) { self.from = from; self.to = to }
    public func covers(_ date: Date) -> Bool { date >= from && date <= to }
}

/// One per device, rewritten on every flush. Its job is to make loss detectable:
/// if the manifest claims sequence 900 and the segments only reach 812, the log
/// is incomplete and the app says so instead of quietly showing less.
public struct LogManifest: Codable, Hashable, Sendable {
    public struct Segment: Codable, Hashable, Sendable {
        public var name: String
        public var firstSequence: Int
        public var lastSequence: Int
        public var recordCount: Int
        public init(name: String, firstSequence: Int, lastSequence: Int, recordCount: Int) {
            self.name = name; self.firstSequence = firstSequence
            self.lastSequence = lastSequence; self.recordCount = recordCount
        }
    }

    public var formatVersion: Int
    public var deviceID: UUID
    public var deviceName: String
    public var member: Member
    public var lastSequence: Int
    public var segments: [Segment]
    public var updatedAt: Date
    /// Stretches during which this device was running and watching. A machine that
    /// was awake would have recorded its own user's edits, so its silence during a
    /// window is evidence in itself — see `AuthorshipResolver`.
    public var awakeWindows: [AwakeWindow]

    public init(formatVersion: Int = logFormatVersion, deviceID: UUID, deviceName: String,
                member: Member, lastSequence: Int = 0, segments: [Segment] = [],
                updatedAt: Date, awakeWindows: [AwakeWindow] = []) {
        self.formatVersion = formatVersion; self.deviceID = deviceID; self.deviceName = deviceName
        self.member = member; self.lastSequence = lastSequence
        self.segments = segments; self.updatedAt = updatedAt; self.awakeWindows = awakeWindows
    }
}
