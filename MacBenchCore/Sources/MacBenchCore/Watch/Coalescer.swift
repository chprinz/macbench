import Foundation

/// One filesystem event, already resolved to a node.
public struct RawFileEvent: Sendable, Hashable {
    public var nodeID: UUID
    public var relativePath: String
    public var isDirectory: Bool
    public var type: FileEventType
    /// The file's own modification date: the moment the work happened. This is what
    /// the timeline shows, on both machines.
    public var contentDate: Date
    /// When this machine noticed. Local only — sync can deliver hours late.
    public var observedAt: Date
    public var fromPath: String?
    /// False when the change looks like it arrived through file sync rather than
    /// being made here. Carried through folding so that one suspicious event in a
    /// window is enough to stop this machine claiming the work.
    public var isLocalOrigin: Bool = true
    /// Replayed from the event history after a restart: it happened while the app
    /// was closed, so neither its time nor its origin was seen.
    public var isReplayed = false

    public init(nodeID: UUID, relativePath: String, isDirectory: Bool, type: FileEventType,
                contentDate: Date, observedAt: Date, fromPath: String? = nil) {
        self.nodeID = nodeID; self.relativePath = relativePath; self.isDirectory = isDirectory
        self.type = type; self.contentDate = contentDate; self.observedAt = observedAt
        self.fromPath = fromPath
    }
}

public struct CoalescedEvent: Sendable, Hashable {
    public var nodeID: UUID
    public var relativePath: String
    public var isDirectory: Bool
    public var event: FileEvent
    public var contentDate: Date
    public var observedAt: Date
    public var isLocalOrigin: Bool = true

    public var dedupKey: String {
        DedupKey.make(nodeID: nodeID, event: event.type, at: contentDate)
    }
}

/// A change that has been seen but not yet written as an entry, because its
/// window is still open. Surfaced so the app can say "something is happening"
/// instead of looking dead for twenty minutes.
public struct PendingChange: Sendable, Hashable, Identifiable {
    public var nodeID: UUID
    public var relativePath: String
    public var type: FileEventType
    public var count: Int
    public var dueAt: Date
    public var id: UUID { nodeID }
}

public struct CoalescingPolicy: Sendable, Hashable {
    /// Saves closer together than this are one save. Most apps write a document
    /// two or three times in a row.
    public var saveCollapse: TimeInterval = 5
    /// Quiet changes are gathered this long before they become one entry.
    public var quietWindow: TimeInterval = 20 * 60
    /// Loud events wait only for the churn to settle. Long enough to swallow the
    /// write-temp-then-rename dance, short enough to feel immediate.
    public var loudSettle: TimeInterval = 30

    public init() {}
    public init(saveCollapse: TimeInterval, quietWindow: TimeInterval, loudSettle: TimeInterval) {
        self.saveCollapse = saveCollapse
        self.quietWindow = quietWindow
        self.loudSettle = loudSettle
    }
}

/// Folds a storm of filesystem events into the handful of statements a person
/// actually wants to read.
public struct Coalescer: Sendable {
    private struct Bucket {
        var nodeID: UUID
        var relativePath: String
        var isDirectory: Bool
        var openedAt: Date
        var lastObservedAt: Date
        var contentDate: Date
        var count: Int
        var types: [FileEventType]
        var fromPath: String?
        var isLocalOrigin: Bool
        var isReplayed: Bool
        var lastSameTypeAt: [FileEventType: Date]
    }

    public var policy: CoalescingPolicy
    private var buckets: [UUID: Bucket] = [:]

    public init(policy: CoalescingPolicy = CoalescingPolicy()) {
        self.policy = policy
    }

    public var pendingCount: Int { buckets.count }

    public mutating func ingest(_ event: RawFileEvent) {
        if var bucket = buckets[event.nodeID] {
            // Same kind of event again within a heartbeat: one save, not two.
            if let previous = bucket.lastSameTypeAt[event.type],
               event.observedAt.timeIntervalSince(previous) < policy.saveCollapse {
                bucket.contentDate = max(bucket.contentDate, event.contentDate)
                bucket.lastObservedAt = event.observedAt
                bucket.lastSameTypeAt[event.type] = event.observedAt
                buckets[event.nodeID] = bucket
                return
            }
            bucket.count += 1
            // A disappearance says nothing about who made the change that follows
            // it: a rename or a replace carries its own evidence.
            bucket.isLocalOrigin = bucket.types.allSatisfy { $0 == .removed }
                ? event.isLocalOrigin
                : bucket.isLocalOrigin && event.isLocalOrigin
            bucket.isReplayed = bucket.isReplayed || event.isReplayed
            bucket.types.append(event.type)
            bucket.contentDate = max(bucket.contentDate, event.contentDate)
            bucket.lastObservedAt = event.observedAt
            bucket.lastSameTypeAt[event.type] = event.observedAt
            bucket.relativePath = event.relativePath
            if bucket.fromPath == nil { bucket.fromPath = event.fromPath }
            buckets[event.nodeID] = bucket
        } else {
            buckets[event.nodeID] = Bucket(
                nodeID: event.nodeID, relativePath: event.relativePath,
                isDirectory: event.isDirectory, openedAt: event.observedAt,
                lastObservedAt: event.observedAt, contentDate: event.contentDate,
                count: 1, types: [event.type], fromPath: event.fromPath,
                isLocalOrigin: event.isLocalOrigin, isReplayed: event.isReplayed,
                lastSameTypeAt: [event.type: event.observedAt])
        }
    }

    /// Emits everything whose window has closed.
    public mutating func drain(now: Date) -> [CoalescedEvent] {
        var ready: [CoalescedEvent] = []
        for (id, bucket) in buckets where isDue(bucket, now: now) {
            buckets.removeValue(forKey: id)
            if let event = resolve(bucket) { ready.append(event) }
        }
        return ready.sorted { $0.contentDate < $1.contentDate }
    }

    /// Emits everything regardless of timing. Used on quit and before sleep, so a
    /// pending window is never lost.
    public mutating func drainAll() -> [CoalescedEvent] {
        let all = buckets.values.compactMap(resolve)
        buckets.removeAll()
        return all.sorted { $0.contentDate < $1.contentDate }
    }

    /// When the next bucket wants attention, so the timer can sleep until then.
    public func nextDeadline() -> Date? {
        buckets.values.map(deadline).min()
    }

    /// What is currently in flight, newest window first.
    public func pending() -> [PendingChange] {
        buckets.values.map { bucket in
            PendingChange(nodeID: bucket.nodeID, relativePath: bucket.relativePath,
                          type: bucket.types.last ?? .modified, count: bucket.count,
                          dueAt: deadline(bucket))
        }
        .sorted { $0.dueAt < $1.dueAt }
    }

    private func deadline(_ bucket: Bucket) -> Date {
        let loudest = bucket.types.map(\.loudness).max() ?? .quiet
        return loudest >= .medium
            ? bucket.lastObservedAt.addingTimeInterval(policy.loudSettle)
            : min(bucket.openedAt.addingTimeInterval(policy.quietWindow),
                  bucket.lastObservedAt.addingTimeInterval(policy.quietWindow))
    }

    private func isDue(_ bucket: Bucket, now: Date) -> Bool {
        now >= deadline(bucket)
    }

    private func resolve(_ bucket: Bucket) -> CoalescedEvent? {
        // A file that appeared and vanished inside one window never really existed:
        // that is an application writing a scratch file, not work anyone did.
        if bucket.types.contains(.created), bucket.types.last == .removed { return nil }

        let type: FileEventType
        if bucket.types.contains(.created) { type = .created }
        else if bucket.types.last == .removed { type = .removed }
        else if bucket.types.contains(.moved) { type = .moved }
        else if bucket.types.contains(.renamed) { type = .renamed }
        else { type = .modified }

        return CoalescedEvent(
            nodeID: bucket.nodeID,
            relativePath: bucket.relativePath,
            isDirectory: bucket.isDirectory,
            event: FileEvent(type: type, count: bucket.count, fromPath: bucket.fromPath,
                             backfilled: bucket.isReplayed),
            contentDate: bucket.contentDate,
            observedAt: bucket.lastObservedAt,
            isLocalOrigin: bucket.isLocalOrigin)
    }
}
