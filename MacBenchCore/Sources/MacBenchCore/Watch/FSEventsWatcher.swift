import Foundation
import CoreServices

/// A raw filesystem notification, before we work out what it means.
public struct FSNotification: Sendable, Hashable {
    public var path: String
    public var eventID: UInt64
    public var isDirectory: Bool
    public var isFile: Bool
    public var created: Bool
    public var removed: Bool
    public var renamed: Bool
    public var modified: Bool
}

public struct FSBatch: Sendable {
    public var notifications: [FSNotification] = []
    public var lastEventID: UInt64 = 0
    /// The kernel or the daemon dropped events, or the id space wrapped. Whatever
    /// we think we know about the folder is now unreliable and only a full scan
    /// can restore it. This is the case that must never be swallowed.
    public var needsFullScan = false
    /// The watched folder itself was moved, renamed or deleted.
    public var rootChanged = false
    /// The replay of events that happened while we were away is finished.
    public var historyDone = false
}

/// Thin wrapper around FSEvents.
///
/// Started from the last event id we processed rather than "from now", so the
/// changes made while the app was closed still arrive. If that id is too old for
/// the system's history, the caller is told to scan instead.
public final class FSEventsWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (FSBatch) -> Void

    private let root: URL
    private let handler: Handler
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private let latency: CFTimeInterval

    public init(root: URL, sinceEventID: UInt64?, latency: TimeInterval = 1.0,
                queue: DispatchQueue = DispatchQueue(label: "studio.macbench.fsevents"),
                handler: @escaping Handler) {
        self.root = root
        self.handler = handler
        self.queue = queue
        self.latency = latency
        self.pendingSince = sinceEventID
    }

    private var pendingSince: UInt64?

    public var lastEventID: UInt64 {
        guard let stream else { return pendingSince ?? 0 }
        return UInt64(FSEventStreamGetLatestEventId(stream))
    }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let since = pendingSince.map { FSEventStreamEventId($0) }
            ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, ids in
                guard let info else { return }
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.receive(count: count, paths: paths, flags: flags, ids: ids)
            },
            &context,
            [root.path(percentEncoded: false)] as CFArray,
            since, latency, flags)
        else { return false }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        return FSEventStreamStart(created)
    }

    public func stop() {
        guard let stream else { return }
        pendingSince = UInt64(FSEventStreamGetLatestEventId(stream))
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func receive(count: Int,
                         paths: UnsafeMutableRawPointer,
                         flags: UnsafePointer<FSEventStreamEventFlags>,
                         ids: UnsafePointer<FSEventStreamEventId>) {
        guard let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
        var batch = FSBatch()
        for index in 0..<count {
            let flag = Int(flags[index])
            batch.lastEventID = max(batch.lastEventID, UInt64(ids[index]))

            if flag & kFSEventStreamEventFlagMustScanSubDirs != 0
                || flag & kFSEventStreamEventFlagUserDropped != 0
                || flag & kFSEventStreamEventFlagKernelDropped != 0
                || flag & kFSEventStreamEventFlagEventIdsWrapped != 0 {
                batch.needsFullScan = true
            }
            if flag & kFSEventStreamEventFlagRootChanged != 0 { batch.rootChanged = true }
            if flag & kFSEventStreamEventFlagHistoryDone != 0 { batch.historyDone = true }
            guard index < list.count else { continue }

            let isDirectory = flag & kFSEventStreamEventFlagItemIsDir != 0
            let isFile = flag & kFSEventStreamEventFlagItemIsFile != 0
            guard isDirectory || isFile else { continue }

            batch.notifications.append(FSNotification(
                path: list[index],
                eventID: UInt64(ids[index]),
                isDirectory: isDirectory,
                isFile: isFile,
                created: flag & kFSEventStreamEventFlagItemCreated != 0,
                removed: flag & kFSEventStreamEventFlagItemRemoved != 0,
                renamed: flag & kFSEventStreamEventFlagItemRenamed != 0,
                // Metadata-only churn (permissions, extended attributes) is not a
                // change anyone wants to read about.
                modified: flag & kFSEventStreamEventFlagItemModified != 0))
        }
        guard !batch.notifications.isEmpty || batch.needsFullScan
                || batch.rootChanged || batch.historyDone else { return }
        handler(batch)
    }

    /// Identifies the volume's event-id history. Apple's own mechanism: when this
    /// changes, every event id we stored is meaningless and replay is impossible.
    public static func historyUUID(for root: URL) -> UUID? {
        var info = stat()
        guard stat(root.path(percentEncoded: false), &info) == 0 else { return nil }
        guard let cf = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, cf) as String)
    }

    /// Whether we may replay from `storedEventID` instead of comparing the whole
    /// folder. Saying yes when the answer is no would lose changes silently, so
    /// every uncertainty resolves to no.
    public static func canReplay(storedEventID: UInt64, storedHistoryUUID: UUID?, root: URL) -> Bool {
        guard storedEventID > 0, let stored = storedHistoryUUID else { return false }
        guard let current = historyUUID(for: root), current == stored else { return false }
        return storedEventID <= UInt64(FSEventsGetCurrentEventId())
    }
}
