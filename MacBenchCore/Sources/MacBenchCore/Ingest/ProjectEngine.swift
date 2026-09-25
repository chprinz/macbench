import Foundation
import GRDB

/// Runs one project: watches its folder, decides what is worth saying, writes it
/// to this device's log, and folds in what the other machines wrote.
public actor ProjectEngine {

    public enum Phase: Sendable, Hashable, Equatable {
        case stopped
        /// First time this folder is seen. The index is built in silence — the
        /// timeline starts the day the app was installed, not with a thousand
        /// entries for files that were always there.
        case buildingIndex(found: Int)
        /// Comparing the folder against the index because events could not be replayed.
        case catchingUp
        case live
    }

    public struct Status: Sendable, Hashable {
        public var phase: Phase = .stopped
        public var pendingEvents = 0
        /// Changes seen but not yet written, with the moment their window closes.
        public var pending: [PendingChange] = []
        /// Changes that look like they arrived through sync. Held briefly in case
        /// the machine they happened on says so itself.
        public var deferredIncoming = 0
        public var lastSync: SyncReport?
        public var unresolvedConflicts: [String] = []
        /// What is wrong right now, one line per kind. Each is taken back by the
        /// next success of the same kind: a single "last error" was set and never
        /// cleared, so a log that could not be written for a minute went on saying
        /// so until the app was restarted — and a warning that is not true any
        /// more teaches people to ignore the ones that are.
        public var problems: [Problem: String] = [:]
        /// Records waiting to be written to this Mac's log. Everything here has
        /// happened on this Mac and has not reached the others yet.
        public var unwrittenRecords = 0
    }

    public enum Problem: Int, Sendable, Hashable, Comparable, CaseIterable {
        /// The folder was moved or renamed under the engine. Lasts until it is
        /// started again.
        case folder
        /// This Mac's log could not be written: the other Macs are not told.
        case log
        /// The index refused something.
        case index
        /// The other Macs' logs could not be read.
        case sync

        public static func < (lhs: Problem, rhs: Problem) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // MARK: - Configuration

    private let projectID: UUID
    private let root: URL
    private let store: Store
    private var identity: LocalIdentity
    private let clock: any Clock
    private let writer: DeviceLogWriter
    private var unwritten: UnwrittenQueue
    private let peerSync: PeerSync
    private let inspector = ICloudInspector()
    private let materialisation = MaterialisationLog()
    private let resolver = AuthorshipResolver()
    /// Who iCloud says last edited a file. Passed in so tests can play iCloud.
    private let sharedEditor: @Sendable (URL) -> SharedEditor
    private let lineCounter: LineCounter

    private var exclusions: ExclusionRules
    private var coalescer = Coalescer()
    private var watcher: FSEventsWatcher?
    private var drainTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var batchDelivery: AsyncStream<FSBatch>.Continuation?
    private var pollTask: Task<Void, Never>?
    private var pendingRemovals: [UInt64: (node: Node, at: Date)] = [:]
    private var deferredIncoming: [(entry: Entry, until: Date)] = []
    /// True while the watcher is still delivering history from before this start.
    private var replaying = false
    /// How far the event stream has been *handled*, as opposed to delivered. A
    /// batch is handed over and then waits its turn on this actor; the stream's
    /// own "latest id" already counts it, so remembering that as the cursor could
    /// step over a batch nobody had looked at yet.
    private var handledEventID: UInt64?
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]

    public private(set) var status = Status() {
        didSet {
            guard status != oldValue else { return }
            for continuation in statusContinuations.values { continuation.yield(status) }
        }
    }

    /// How long a change that looks like it came from sync waits for its author's
    /// log before being recorded without a name. Long enough for iCloud on a good
    /// day, short enough that nothing sits invisible for an afternoon.
    /// How long a deleted node stays in the lists before it moves to the archive.
    /// Zero keeps everything visible forever.
    public var archiveAfterDays = 90

    private let incomingGrace: TimeInterval = 10 * 60
    /// How old a change has to be before iCloud's word on its editor outweighs
    /// this Mac's own impression that it was made here. A save of our own shows
    /// the previous editor until its upload is through, which takes moments; a
    /// Pages document arriving from the other Mac can look like a save made here,
    /// because a package reports no download of its own.
    private let editorSettle: TimeInterval = 5 * 60
    /// A deletion is held this long in case it turns out to be the first half of a
    /// move, which arrives as a separate notification.
    private let moveGrace: TimeInterval = 15

    public init(projectID: UUID, root: URL, store: Store, identity: LocalIdentity,
                supportDirectory: URL, clock: any Clock = SystemClock(),
                sharedEditor: @escaping @Sendable (URL) -> SharedEditor = { ICloudInspector().sharedEditor(of: $0) }) throws {
        self.projectID = projectID
        self.sharedEditor = sharedEditor
        self.root = root
        self.store = store
        self.identity = identity
        self.clock = clock
        self.writer = try DeviceLogWriter(root: root, identity: identity, clock: clock)
        self.unwritten = UnwrittenQueue(url: supportDirectory
            .appending(path: "unwritten", directoryHint: .isDirectory)
            .appending(path: "\(projectID.uuidString).jsonl"))
        self.peerSync = PeerSync(store: store, projectID: projectID, selfDeviceID: identity.deviceID)
        self.lineCounter = LineCounter(
            snapshotDirectory: supportDirectory.appending(path: "line-snapshots", directoryHint: .isDirectory))
        self.exclusions = ExclusionRules(userExcludedPaths: (try? store.excludedPaths(for: projectID)) ?? [])
    }

    public func statusUpdates() -> AsyncStream<Status> {
        AsyncStream { continuation in
            let id = UUID()
            statusContinuations[id] = continuation
            continuation.yield(status)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) { statusContinuations[id] = nil }

    // MARK: - Lifecycle

    public func start() async {
        guard case .stopped = status.phase else { return }
        exclusions = ExclusionRules(userExcludedPaths: (try? store.excludedPaths(for: projectID)) ?? [])
        _ = try? store.foldDocumentPackages(projectID: projectID)
        try? await writer.recordHeartbeat(now: clock.now)
        // Left over from the last run, before anything new goes behind it.
        if !unwritten.isEmpty { await record([]) }

        // Read what the others said first. A change of theirs that is already
        // explained needs no guessing when our own watcher reports it.
        await pullPeers()

        let cursor = (try? store.fsEventCursor(for: projectID)) ?? (eventID: nil, lastScanAt: nil)
        let historyUUID = try? store.setting(historyKey, as: UUID.self)
        let lookedBefore = (try? hasLookedBefore(lastScanAt: cursor.lastScanAt)) ?? true

        // Every branch has to end with a running watcher. Getting here without one
        // is not visible from inside the app — it looks exactly like a quiet
        // afternoon — so the start is written once, after the branch, rather than
        // in each arm where it can be left out.
        var replayFrom: UInt64?
        if !lookedBefore {
            await buildInitialIndex()
            await announceJoining()
        } else if let eventID = cursor.eventID,
                  FSEventsWatcher.canReplay(storedEventID: eventID,
                                            storedHistoryUUID: historyUUID ?? nil, root: root) {
            replayFrom = eventID
        } else {
            // The only remaining honest option: compare the folder against the
            // index and report what differs, flagged as reconstructed.
            await catchUp(trustingOwnAwakeWindows: true)
        }
        startWatcher(since: replayFrom)

        try? store.archiveDeletedNodes(olderThan: archiveAfterDays, now: clock.now)
        status.phase = .live
        startPolling()
    }

    public func stop() async {
        drainTask?.cancel(); drainTask = nil
        pollTask?.cancel(); pollTask = nil
        watcher?.stop()
        watcher = nil
        // Batches not handled yet lie past the cursor and are replayed next time.
        batchDelivery?.finish(); batchDelivery = nil
        batchTask?.cancel(); batchTask = nil
        // Nothing pending may be lost on quit: flush the windows that are still open.
        await emit(coalescer.drainAll())
        await flushDeferred(force: true)
        // Only now, with everything written, may the cursor move past it.
        rememberEventCursor(handledEventID, at: clock.now)
        try? await writer.recordHeartbeat(now: clock.now, closing: true)
        status.phase = .stopped
    }

    /// Records how far the event stream has been consumed.
    ///
    /// Only while nothing is still in flight. The cursor means "everything up to
    /// here is on record", and a change sitting in its twenty-minute window is
    /// not on record yet. Moving the cursor past it means the replay after a
    /// crash starts on the far side of the event, and nothing ever mentions the
    /// change again — the index cannot find it either, because a version of the
    /// file is only marked as indexed once its entry exists.
    private func rememberEventCursor(_ eventID: UInt64?, at date: Date) {
        guard coalescer.pendingCount == 0, deferredIncoming.isEmpty else { return }
        guard let eventID, eventID > 0 else { return }
        try? store.setFSEventCursor(eventID, scannedAt: date, for: projectID)
    }

    private var historyKey: String { "fsevents.history.\(projectID.uuidString)" }

    /// Whether this Mac has ever looked at the folder itself.
    ///
    /// Not whether the index knows any files. The other Macs' logs are read
    /// first, and they register every file in the folder — so a Mac joining a
    /// folder with a history used to know thousands of files it had never seen,
    /// skip the silent first look, compare the folder against those instead, and
    /// report every one of them as changed.
    private func hasLookedBefore(lastScanAt: Date?) throws -> Bool {
        if lastScanAt != nil { return true }
        return try store.read { [projectID] db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM node WHERE projectID = ? AND inode IS NOT NULL)
                """, arguments: [projectID]) ?? false
        }
    }

    // MARK: - Indexing

    private func buildInitialIndex() async {
        status.phase = .buildingIndex(found: 0)
        status.problems[.index] = nil
        let scanner = FileScanner(exclusions: exclusions)
        let result = scanner.scan(root: root)
        let now = clock.now
        var registrations: [LogBody] = []
        var batch: [IndexedNode] = []

        // Written in chunks rather than one file at a time. This is the silent
        // pass — no entries come out of it — so the only thing on screen is the
        // count, and it has to keep moving without a transaction per file behind it.
        var found = 0
        func flush() {
            guard !batch.isEmpty else { return }
            do { try store.upsert(nodes: batch) }
            catch { status.problems[.index] = error.localizedDescription }
            found += batch.count
            batch.removeAll(keepingCapacity: true)
            status.phase = .buildingIndex(found: found)
        }

        // Joining a folder with a history, most of it is registered already by the
        // other Macs' logs, read just before this. Those files keep the ids the
        // others use for them: a second id minted here would be a second node for
        // one path, which the index refuses — and it refused the whole batch the
        // file was in, leaving five hundred files unindexed without a word.
        let registered = (try? store.read { [projectID] db in
            try NodeRow.filter(Column("projectID") == projectID).fetchAll(db)
        }).map { rows in
            Dictionary(rows.map { ($0.relativePath, $0.node) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]

        for item in result.items {
            let known = registered[item.relativePath]
            let node = Node(id: known?.id ?? mintNodeID(for: item.relativePath),
                            projectID: projectID, relativePath: item.relativePath,
                            isDirectory: item.isDirectory,
                            firstSeenAt: known?.firstSeenAt ?? now, lastSeenAt: now)
            var stored = node
            stored.contentModifiedAt = item.contentModifiedAt
            stored.fileSize = item.fileSize
            batch.append(IndexedNode(node: stored, inode: item.fileIdentifier.map(Int64.init)))
            if !item.isDirectory, item.isMaterialised {
                primeLineSnapshot(nodeID: node.id, relativePath: item.relativePath, size: item.fileSize)
            }
            if known == nil {
                registrations.append(.node(NodeRecord(id: node.id, path: item.relativePath,
                                                      isDirectory: item.isDirectory, firstSeenAt: now)))
            }
            if batch.count >= 500 { flush() }
        }
        flush()
        await record(registrations)
        try? store.setFSEventCursor(nil, scannedAt: now, for: projectID)
        rememberHistoryUUID()
    }

    /// The one entry an initial index does produce.
    ///
    /// Everything already in the folder is indexed in silence — that is the rule,
    /// and it is why a new project does not arrive as two thousand changes. But
    /// the person doing the indexing is new to whoever else is in the folder, and
    /// "since when is she in this?" is a question the stream should be able to
    /// answer. Written where it happens, by the machine it happens on: the second
    /// Mac of the same person reports the same fact, not a second one, and the
    /// dedup key folds the two together.
    private func announceJoining() async {
        let now = clock.now
        let entry = Entry(projectID: projectID, authorID: identity.member.id,
                          createdAt: now, observedAt: now, kind: .system,
                          // The sentence is the fallback for a version that
                          // predates notices and would otherwise show an empty
                          // line. Every reader that knows what a notice is builds
                          // this sentence itself, in its own language.
                          text: "\(identity.member.name) is now in this project",
                          notice: .joined,
                          dedupKey: DedupKey.joined(memberID: identity.member.id))
        await commit(entry)
    }

    /// `trustingOwnAwakeWindows` decides whether this machine's own running time
    /// counts as evidence. At start-up it does: a stretch we were watching is a
    /// stretch we would have reported, so a change from then was not ours. After a
    /// dropped batch or a manual re-check it does not — we were demonstrably
    /// running and still missed it, so our own presence proves nothing.
    private func catchUp(trustingOwnAwakeWindows: Bool) async {
        status.phase = .catchingUp
        let scanner = FileScanner(exclusions: exclusions)
        let scan = scanner.scan(root: root)
        let known: [NodeRow] = (try? store.read { [projectID] db in
            try NodeRow.filter(sql: "projectID = ?", arguments: [projectID]).fetchAll(db)
        }) ?? []
        let identifiers = known.reduce(into: [UUID: UInt64]()) { result, row in
            if let inode = row.inode { result[row.id] = UInt64(inode) }
        }
        let diff = Reconciler.compare(scanned: scan.items, known: known.map(\.node),
                                      knownIdentifiers: identifiers)
        let now = clock.now
        let peers = await peerAwareness()
        let selfWindows = trustingOwnAwakeWindows ? await writer.awakeWindows() : []

        var events: [CoalescedEvent] = []
        var registrations: [LogBody] = []
        for item in diff.created {
            // A file back at a path we already know keeps that path's node, and
            // with it everything anyone ever wrote about it.
            let returning = try? store.node(projectID: projectID, relativePath: item.relativePath)
            events.append(backfillEvent(item: item, node: returning, type: .created, now: now,
                                        registrations: &registrations))
        }
        for (node, item) in diff.modified {
            events.append(backfillEvent(item: item, node: node, type: .modified, now: now,
                                        registrations: &registrations))
        }
        for (node, item) in diff.moved {
            // Deliberately not `backfillEvent`: that registers a node for the path,
            // and the destination path belongs to the node that is moving into it.
            let from = node.relativePath
            try? store.moveNode(id: node.id, to: item.relativePath, at: now)
            var updated = node
            updated.relativePath = item.relativePath
            updated.contentModifiedAt = item.contentModifiedAt
            updated.fileSize = item.fileSize
            updated.lastSeenAt = now
            try? store.upsert(node: updated, inode: item.fileIdentifier.map(Int64.init))
            await record([.nodeRename(NodeRenameRecord(
                id: node.id, from: from, to: item.relativePath, at: now,
                isDirectory: item.isDirectory))])
            events.append(CoalescedEvent(
                nodeID: node.id, relativePath: item.relativePath, isDirectory: item.isDirectory,
                event: FileEvent(type: .moved, fromPath: from, backfilled: true),
                contentDate: item.contentModifiedAt ?? now, observedAt: now))
        }
        let seenHere = Set(known.filter { $0.inode != nil }.map(\.id))
        for node in diff.removed where seenHere.contains(node.id) {
            try? store.setNodeState(.deleted, id: node.id, at: now)
            lineCounter.forget(node.id)
            await record([.nodeState(NodeStateRecord(id: node.id, state: .deleted, at: now))])
            events.append(CoalescedEvent(
                nodeID: node.id, relativePath: node.relativePath, isDirectory: node.isDirectory,
                event: FileEvent(type: .removed, backfilled: true),
                contentDate: node.contentModifiedAt ?? now, observedAt: now))
        }

        if !registrations.isEmpty { await record(registrations) }

        for event in events {
            let verdict = resolver.inferBackfill(changeAt: event.contentDate,
                                                 selfMember: identity.member.id,
                                                 selfAwake: selfWindows, peers: peers)
            await record(event, verdict: verdict, deferIfIncoming: false)
        }
        try? store.setFSEventCursor(nil, scannedAt: now, for: projectID)
        rememberHistoryUUID()
    }

    private func backfillEvent(item: ScannedItem, node existing: Node?, type: FileEventType,
                               now: Date, registrations: inout [LogBody]) -> CoalescedEvent {
        let id = existing?.id ?? mintNodeID(for: item.relativePath)
        let node = Node(id: id, projectID: projectID, relativePath: item.relativePath,
                        isDirectory: item.isDirectory,
                        firstSeenAt: existing?.firstSeenAt ?? item.contentModifiedAt ?? now,
                        lastSeenAt: now)
        // The content watermark is deliberately not written here: see `commit`.
        try? store.upsert(node: node, inode: item.fileIdentifier.map(Int64.init))
        if existing == nil {
            registrations.append(.node(NodeRecord(id: id, path: item.relativePath,
                                                  isDirectory: item.isDirectory,
                                                  firstSeenAt: node.firstSeenAt)))
            if !item.isDirectory, item.isMaterialised {
                primeLineSnapshot(nodeID: id, relativePath: item.relativePath, size: item.fileSize)
            }
        }
        return CoalescedEvent(
            nodeID: id, relativePath: item.relativePath, isDirectory: item.isDirectory,
            event: FileEvent(type: type, backfilled: true),
            contentDate: item.contentModifiedAt ?? now, observedAt: now)
    }

    /// The id for a file appearing at `path` for the first time.
    ///
    /// Ids are derived from the path so that two machines agree on them without
    /// asking each other. A path can be used twice, though: rename
    /// `plakat.afdesign` to `plakat_v1.afdesign` and export a fresh one under the
    /// old name, and the derived id already belongs to the file that moved away.
    /// Handing it out again does not create a duplicate — it silently drags the
    /// older file's row, and its whole conversation, onto the new file.
    ///
    /// The same collision happens between projects: the path is relative, so every
    /// client folder derives the same id for its own `Briefing.pdf`, and the second
    /// one used to take the first one's row and vanish from the index.
    ///
    /// So the derivation is salted until it lands on an id nobody holds. If the
    /// other Mac salts differently, because it saw the rename in a different order
    /// or does not have the other client's folder at all, the two ids meet in
    /// `PeerSync.ensureNode` and are reconciled there, exactly as for any other
    /// disagreement about identity.
    private func mintNodeID(for path: String) -> UUID {
        var candidate = Namespace.nodeID(firstSeenPath: path)
        for salt in 1...16 {
            guard let taken = try? store.anyNode(id: candidate) else { return candidate }
            // Ours already, at this very path: nothing to avoid.
            if taken.projectID == projectID, taken.relativePath == path { return candidate }
            candidate = Namespace.nodeID(firstSeenPath: "\(path)#\(salt)")
        }
        return candidate
    }

    /// Fingerprints a small text file so the next change to it can be reported as
    /// lines added and removed instead of a bare "replaced".
    private func primeLineSnapshot(nodeID: UUID, relativePath: String, size: Int64?) {
        let url = root.appending(path: relativePath)
        _ = lineCounter.delta(for: url, nodeID: nodeID, fileSize: size)
    }

    private func rememberHistoryUUID() {
        if let uuid = FSEventsWatcher.historyUUID(for: root) {
            try? store.setSetting(historyKey, value: uuid)
        }
    }

    // MARK: - Watching

    private func startWatcher(since: UInt64?) {
        replaying = since != nil
        // Before the stream exists, so that anything it goes on to deliver lies
        // beyond this point and would be replayed if it never got handled.
        handledEventID = since ?? UInt64(FSEventsGetCurrentEventId())
        // One queue, one reader, so batches are handled in the order FSEvents
        // delivered them. A task per batch usually kept that order, a second apart
        // — but nothing guaranteed it, and a deletion handled before the creation
        // it follows is a file that stays.
        let (batches, delivery) = AsyncStream.makeStream(of: FSBatch.self)
        batchDelivery?.finish()
        batchTask?.cancel()
        batchDelivery = delivery
        batchTask = Task { [weak self] in
            for await batch in batches {
                await self?.handle(batch)
            }
        }
        let watcher = FSEventsWatcher(root: root, sinceEventID: since) { batch in
            delivery.yield(batch)
        }
        self.watcher = watcher
        _ = watcher.start()
        rememberHistoryUUID()
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await self?.periodic()
            }
        }
    }

    private func periodic() async {
        if !unwritten.isEmpty { await record([]) }
        try? store.archiveDeletedNodes(olderThan: archiveAfterDays, now: clock.now)
        await pullPeers()
        await flushDeferred(force: false)
        try? await writer.recordHeartbeat(now: clock.now)
        rememberEventCursor(handledEventID, at: clock.now)
    }

    public func pullPeers() async {
        do {
            let report = try peerSync.pull(root: root, now: clock.now)
            status.lastSync = report
            status.problems[.sync] = nil
            // A peer explaining a change we were unsure about resolves it now.
            await flushDeferred(force: false)
        } catch {
            status.problems[.sync] = error.localizedDescription
        }
    }

    private func peerAwareness() async -> [PeerAwareness] {
        DeviceLogReader.peers(in: root)
            .filter { $0.deviceID != identity.deviceID }
            .compactMap { peer in
                guard let manifest = peer.manifest else { return nil }
                return PeerAwareness(memberID: manifest.member.id, windows: manifest.awakeWindows)
            }
    }

    private func handle(_ batch: FSBatch) async {
        if batch.rootChanged {
            status.problems[.folder] = "The project folder was moved or renamed."
            return
        }
        if batch.needsFullScan {
            // Events were dropped. Anything else here would be a guess.
            await catchUp(trustingOwnAwakeWindows: false)
            // The comparison accounts for everything up to here.
            if batch.lastEventID > 0 { handledEventID = max(handledEventID ?? 0, batch.lastEventID) }
            return
        }

        let now = clock.now
        var peerLogTouched = false
        let isReplay = replaying
        if batch.historyDone { replaying = false }
        // A save touches a dozen files inside a package; the document changed once.
        var packagesSeen: Set<String> = []

        for var notification in batch.notifications {
            guard var relative = relativePath(of: notification.path) else { continue }

            if relative.hasPrefix(LogLayout.directoryName + "/") {
                if !relative.contains(identity.deviceID.uuidString) { peerLogTouched = true }
                continue
            }
            // A vanishing `.name.icloud` placeholder is sync putting a file in place.
            // The strongest evidence there is that a change is not ours.
            let name = (relative as NSString).lastPathComponent
            if let target = ICloudInspector.placeholderTarget(ofFileName: name) {
                let parent = (relative as NSString).deletingLastPathComponent
                let targetPath = parent.isEmpty ? target : parent + "/" + target
                materialisation.note(path: targetPath, at: now)
                continue
            }
            if let package = DocumentPackage.root(of: relative) {
                guard packagesSeen.insert(package).inserted else { continue }
                relative = package
                notification.isDirectory = false
            }
            if exclusions.isExcluded(relative, isDirectory: notification.isDirectory) { continue }
            await interpret(notification, relative: relative, now: now, replayed: isReplay)
        }

        if peerLogTouched { await pullPeers() }
        publishPending()
        scheduleDrain()
        if batch.lastEventID > 0 { handledEventID = max(handledEventID ?? 0, batch.lastEventID) }
        rememberEventCursor(handledEventID, at: now)
    }

    private func relativePath(of absolute: String) -> String? {
        RelativePath.of(absolute, under: root.path(percentEncoded: false))
    }

    private func interpret(_ notification: FSNotification, relative: String, now: Date,
                           replayed: Bool) async {
        let url = root.appending(path: relative)
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .fileIdentifierKey])
        let exists = values != nil
        let existing = try? store.node(projectID: projectID, relativePath: relative)

        if !exists {
            guard let node = existing, node.state == .present else { return }
            // A file only the other Mac's log knows about, at a path this disk never
            // had it under, was not deleted here. Our copy has not caught up yet —
            // reading that as a deletion put this Mac's name on images vanishing
            // from somebody else's document.
            guard let inode = (try? inode(of: node)) ?? nil else { return }
            // Hold it briefly: the other half of a move usually follows.
            // The ones whose other half never came are deletions after all, and
            // nothing was clearing them out — a long session accumulated every
            // file it had ever seen disappear.
            pendingRemovals = pendingRemovals.filter {
                now.timeIntervalSince($0.value.at) < moveGrace
            }
            pendingRemovals[inode] = (node, now)
            try? store.setNodeState(.deleted, id: node.id, at: now)
            lineCounter.forget(node.id)
            // A vanished file leaves nothing to inspect: sync removing it looks
            // exactly like somebody deleting it here. Whose it was is decided later,
            // once the other Macs had a chance to say — see `resolveUnclaimed`.
            var event = RawFileEvent(nodeID: node.id, relativePath: relative,
                                     isDirectory: node.isDirectory, type: .removed,
                                     contentDate: now, observedAt: now)
            event.isReplayed = replayed
            queue(event, verdict: .unknown)
            return
        }

        let isPackage = DocumentPackage.isPackage(relative)
        let isDirectory = !isPackage && (values?.isDirectory ?? notification.isDirectory)
        var modifiedAt = values?.contentModificationDate ?? now
        let identifier = values?.fileIdentifier
        var size = (values?.fileSize).map(Int64.init)
        if isPackage {
            let stamp = DocumentPackage.stamp(of: url)
            modifiedAt = stamp.modifiedAt ?? modifiedAt
            size = stamp.size
        }

        // Did this file just arrive from somewhere else in the project?
        if let identifier, let pending = pendingRemovals[identifier],
           now.timeIntervalSince(pending.at) < moveGrace, pending.node.relativePath != relative {
            pendingRemovals.removeValue(forKey: identifier)
            let node = pending.node
            try? store.moveNode(id: node.id, to: relative, at: now)
            try? store.setNodeState(.present, id: node.id, at: now)
            let isRename = (node.relativePath as NSString).deletingLastPathComponent
                == (relative as NSString).deletingLastPathComponent
            await record([.nodeRename(NodeRenameRecord(
                id: node.id, from: node.relativePath, to: relative, at: now,
                isDirectory: isDirectory))])
            var event = RawFileEvent(nodeID: node.id, relativePath: relative,
                                     isDirectory: isDirectory,
                                     type: isRename ? .renamed : .moved,
                                     contentDate: modifiedAt, observedAt: now,
                                     fromPath: node.relativePath)
            // Sync carries out the other Mac's move on this disk exactly as a
            // move made here: same file, new place, nothing to inspect. Taken
            // for ours, it put this Mac's name on a folder the other person had
            // moved. So it waits for their log like a deletion does — see
            // `resolveUnclaimed`.
            queue(event, verdict: .unknown)
            return
        }

        // Opening a document touches it — the system notes when it was last
        // used, iCloud updates its bookkeeping — without anybody changing a
        // word. Only a new date or size is a change. Opening the other person's
        // Pages document went down as an edit by whoever opened it.
        if let existing, existing.state == .present, !isDirectory,
           !Reconciler.changed(node: existing, item: ScannedItem(
               relativePath: relative, isDirectory: false, contentModifiedAt: modifiedAt,
               fileSize: size, fileIdentifier: identifier, isMaterialised: true)) {
            return
        }

        var signals = inspector.signals(
            for: url, observedAt: now,
            recentlyMaterialised: materialisation.wasRecentlyMaterialised(path: relative, at: now))
        // The folder's own date says nothing about when the document was saved.
        if isPackage {
            signals.contentAge = now.timeIntervalSince(modifiedAt)
            signals.isPackage = true
        }
        let verdict = resolver.assessLive(signals)

        if inspector.hasUnresolvedConflict(url), !status.unresolvedConflicts.contains(relative) {
            status.unresolvedConflicts.append(relative)
        }

        let type: FileEventType
        let nodeID: UUID
        if let existing, existing.state == .present {
            nodeID = existing.id
            type = .modified
        } else if let existing {
            nodeID = existing.id
            type = .created  // it came back
        } else {
            nodeID = mintNodeID(for: relative)
            type = .created
        }

        // The node's own modification date and size are deliberately left alone
        // until the entry has been written — see `commit`.
        let node = Node(id: nodeID, projectID: projectID, relativePath: relative,
                        isDirectory: isDirectory,
                        firstSeenAt: existing?.firstSeenAt ?? modifiedAt, lastSeenAt: now)
        try? store.upsert(node: node, inode: identifier.map(Int64.init))
        if existing == nil {
            await record([.node(NodeRecord(id: nodeID, path: relative,
                                                           isDirectory: isDirectory,
                                                           firstSeenAt: node.firstSeenAt))])
        }
        guard !isDirectory else { return }

        if type == .created, !isPackage, inspector.isMaterialised(url) {
            primeLineSnapshot(nodeID: nodeID, relativePath: relative, size: size)
        }
        var event = RawFileEvent(nodeID: nodeID, relativePath: relative, isDirectory: false,
                                 type: type, contentDate: modifiedAt, observedAt: now)
        event.isLocalOrigin = verdict == .local
        queue(event, verdict: verdict)
    }

    private func inode(of node: Node) throws -> UInt64? {
        try store.read { db in
            try UInt64.fetchOne(db, sql: "SELECT inode FROM node WHERE id = ?", arguments: [node.id])
        }
    }

    private func queue(_ event: RawFileEvent, verdict: OriginVerdict) {
        var event = event
        event.isLocalOrigin = verdict == .local
        coalescer.ingest(event)
        publishPending()
    }

    private func publishPending() {
        status.pendingEvents = coalescer.pendingCount
        status.pending = coalescer.pending()
    }

    private func scheduleDrain() {
        drainTask?.cancel()
        guard let deadline = coalescer.nextDeadline() else { return }
        let delay = max(0.5, deadline.timeIntervalSince(clock.now))
        drainTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    private func drain() async {
        let due = coalescer.drain(now: clock.now)
        await emit(due)
        publishPending()
        await flushDeferred(force: false)
        scheduleDrain()
    }

    private func emit(_ events: [CoalescedEvent]) async {
        for event in events {
            await record(event, verdict: event.isLocalOrigin ? .local : .incoming,
                         deferIfIncoming: true)
        }
    }

    // MARK: - Writing entries

    private func record(_ event: CoalescedEvent, verdict: OriginVerdict, deferIfIncoming: Bool) async {
        var event = event
        if event.event.type == .removed, event.isDirectory,
           let folder = try? store.node(id: event.nodeID) {
            // A folder dragged to the Trash is one event — the folder left — and
            // says nothing about what was in it. Whatever was inside is gone too;
            // left present, it was still found by search and still listed under
            // tasks, pointing at files that were not there.
            try? store.markDescendantsDeleted(projectID: projectID, folderPath: folder.relativePath,
                                              at: clock.now)
        }
        if event.event.type == .modified, !event.isDirectory,
           !DocumentPackage.isPackage(event.relativePath) {
            let url = root.appending(path: event.relativePath)
            if inspector.isMaterialised(url),
               let delta = lineCounter.delta(for: url, nodeID: event.nodeID,
                                             fileSize: try? fileSize(of: url)),
               !delta.isFirstSnapshot {
                event.event.linesAdded = delta.added
                event.event.linesRemoved = delta.removed
            }
        }

        var author: UUID?
        switch verdict {
        case .local: author = identity.member.id
        case .inferred(let member): author = member
        case .incoming, .unknown: author = nil
        }
        // Where the watching could not tell — or nobody was watching — iCloud's
        // word on who last edited the file is the best evidence there is, better
        // than working out who was awake. Over a save this Mac took for its own
        // only once the change has settled: before that, iCloud may still be
        // showing whoever saved it last time.
        let isSettled = clock.now.timeIntervalSince(event.contentDate) >= editorSettle
        if verdict != .local || event.event.backfilled || isSettled,
           let named = editorAuthor(of: event.relativePath, type: event.event.type,
                                    isDirectory: event.isDirectory,
                                    trustCurrentUser: event.event.backfilled) {
            author = named
        }

        let entry = Entry(projectID: projectID, nodeID: event.nodeID, authorID: author,
                          createdAt: event.contentDate, observedAt: clock.now,
                          kind: .system, text: "", event: event.event,
                          dedupKey: event.dedupKey)

        // Found by comparing the folder, after the others' logs were read: what
        // happened while this app was closed is often something the Mac it
        // happened on has already said. The comparison used to say it again —
        // a file the other Mac added came back as "changed", and a deletion,
        // keyed to the file's own old date, got a second line of its own.
        if event.event.backfilled, isExplained(entry) {
            markAccountedFor(entry)
            return
        }

        // Alone in the folder there is nobody to wait for.
        if author == nil, event.event.type.isUnwitnessable, await peerAwareness().isEmpty {
            var alone = entry
            alone.authorID = await resolveUnclaimed(entry)
            await commit(alone)
            return
        }
        if author == nil, deferIfIncoming {
            // Give the machine it happened on a chance to say so itself, rather
            // than filling the timeline with nameless changes.
            deferredIncoming.append((entry, clock.now.addingTimeInterval(incomingGrace)))
            status.deferredIncoming = deferredIncoming.count
            return
        }
        await commit(entry)
    }

    private func commit(_ entry: Entry) async {
        let outcome: EntryMergeOutcome
        do {
            outcome = try store.merge(entry: entry)
            status.problems[.index] = nil
        } catch {
            status.problems[.index] = error.localizedDescription
            return
        }
        switch outcome {
        case .inserted, .replacedExisting:
            await record([.entry(EntryRecord(entry: entry))])
        case .duplicate, .updated:
            break  // the machine it happened on already said it
        }
        markAccountedFor(entry)
    }

    /// Every record this Mac writes goes through here.
    ///
    /// A write that fails does not lose what it was writing: the records wait in
    /// `unwritten` and go first on the next write, in the order they happened,
    /// with the time they happened. Until then the status says so — a warning
    /// the next successful write takes back. Most callers used to drop a failure
    /// with a `try?`, and a rename or a new file the other Macs were never told
    /// about left no trace here.
    private func record(_ bodies: [LogBody]) async {
        let now = clock.now
        let pending = unwritten.records + bodies.map { PendingRecord(body: $0, at: now) }
        guard !pending.isEmpty else { return }
        let before = await writer.lastSequence
        do {
            try await writer.append(pending)
            unwritten.replace(with: [])
            status.problems[.log] = nil
        } catch {
            // A write that rolled over into a new segment can fail after the
            // first part is on disk. Those are spent; only the rest waits.
            let written = max(0, await writer.lastSequence - before)
            unwritten.replace(with: Array(pending.dropFirst(written)))
            status.problems[.log] = error.localizedDescription
        }
        status.unwrittenRecords = unwritten.records.count
    }

    /// Marks the file as indexed at its current state, now that the change to it
    /// is on record.
    ///
    /// The order matters and used to be the other way round. A quiet change waits
    /// twenty minutes before it becomes an entry; if the file's modification date
    /// is stamped as indexed when the change is *seen*, then quitting inside that
    /// window loses it twice over — the pending window is dropped, and the next
    /// launch's comparison finds nothing to report because the index already
    /// claims to know this version. Which is the silent gap this whole app exists
    /// to avoid.
    private func markAccountedFor(_ entry: Entry) {
        guard let nodeID = entry.nodeID, let event = entry.event, event.type != .removed,
              let node = try? store.node(id: nodeID), !node.isDirectory
        else { return }
        let url = root.appending(path: node.relativePath)
        let stamp: (modifiedAt: Date?, size: Int64?)
        if DocumentPackage.isPackage(node.relativePath) {
            stamp = DocumentPackage.stamp(of: url)
        } else {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            stamp = (values?.contentModificationDate, values?.fileSize.map(Int64.init))
        }
        guard let modified = stamp.modifiedAt else { return }
        // If the file has moved on since the change this entry describes, leave the
        // watermark alone: that newer version is not accounted for by anything.
        guard modified.timeIntervalSince(entry.createdAt) <= 1 else { return }
        try? store.markContentIndexed(nodeID: nodeID, modifiedAt: modified, size: stamp.size)
    }

    /// Writes out changes whose author never turned up. An entry without a name is
    /// worse than one with a name and far better than none at all.
    private func flushDeferred(force: Bool) async {
        guard !deferredIncoming.isEmpty else { return }
        let now = clock.now
        var remaining: [(entry: Entry, until: Date)] = []
        for pending in deferredIncoming {
            if isExplained(pending.entry) {
                // Somebody else's log accounted for it, so the file counts as
                // indexed even though we never wrote an entry of our own.
                markAccountedFor(pending.entry)
                continue
            }
            if force || now >= pending.until {
                var entry = pending.entry
                if entry.event?.type.isUnwitnessable == true {
                    entry.authorID = await resolveUnclaimed(entry)
                } else if let nodeID = entry.nodeID, let event = entry.event,
                          let node = try? store.node(id: nodeID) {
                    // After the full wait, iCloud has caught up, so no name does
                    // mean the person here. Not when quitting cuts the wait short.
                    entry.authorID = editorAuthor(of: node.relativePath, type: event.type,
                                                  isDirectory: node.isDirectory,
                                                  trustCurrentUser: now >= pending.until)
                }
                await commit(entry)
            } else {
                remaining.append(pending)
            }
        }
        deferredIncoming = remaining
        status.deferredIncoming = remaining.count
    }

    /// Whether another Mac's log already accounts for this change.
    ///
    /// A deletion is matched on the file rather than on its dedup key: the key
    /// carries a time, and each Mac only knows when the file vanished from its own
    /// disk, which with sync in between can be hours apart. A move likewise, by
    /// when it was seen: its key carries the file's own date, which a move does
    /// not change, so an old move of the same file would otherwise do.
    private func isExplained(_ entry: Entry) -> Bool {
        (try? store.read { db in
            if let type = entry.event?.type, type == .moved || type == .renamed,
               let nodeID = entry.nodeID {
                return try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM entry WHERE nodeID = ? AND eventType IN (?, ?)
                                  AND authorID IS NOT NULL AND isSuperseded = 0
                                  AND id <> ? AND observedAt >= ?)
                    """, arguments: [nodeID, FileEventType.moved.rawValue,
                                     FileEventType.renamed.rawValue, entry.id,
                                     entry.observedAt.addingTimeInterval(-24 * 3600)]) ?? false
            }
            if entry.event?.type == .removed, let nodeID = entry.nodeID {
                return try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM entry WHERE nodeID = ? AND eventType = ?
                                  AND authorID IS NOT NULL AND isSuperseded = 0
                                  AND id <> ? AND createdAt >= ?)
                    """, arguments: [nodeID, FileEventType.removed.rawValue, entry.id,
                                     entry.createdAt.addingTimeInterval(-24 * 3600)]) ?? false
            }
            // A file the other Mac added reaches this one as a change to a file
            // this Mac already knew — from that Mac's log, which says it was
            // added. That addition is the explanation: without it, a second line
            // went in ten minutes later saying somebody had changed the file.
            var keys = [entry.dedupKey]
            if entry.event?.type == .modified, let nodeID = entry.nodeID {
                keys.append(DedupKey.make(nodeID: nodeID, event: .created, at: entry.createdAt))
            }
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM entry WHERE dedupKey IN (\(placeholders(keys.count)))
                              AND authorID IS NOT NULL AND isSuperseded = 0)
                """, arguments: StatementArguments(keys)) ?? false
        }) ?? false
    }

    /// Who iCloud says made a change, as one of the people in this project.
    ///
    /// Only for a file that was created or saved: the last editor is whoever last
    /// changed the contents, which says nothing about who moved or renamed it, and
    /// a deleted file is not there to ask.
    private func editorAuthor(of relativePath: String, type: FileEventType, isDirectory: Bool,
                              trustCurrentUser: Bool) -> UUID? {
        guard type == .created || type == .modified, !isDirectory else { return nil }
        let editor = sharedEditor(root.appending(path: relativePath))
        return resolver.author(from: editor, selfMember: identity.member.id,
                               others: peerMembers(), trustCurrentUser: trustCurrentUser)
    }

    /// Everybody else in this folder, as their own Macs describe them.
    private func peerMembers() -> [Member] {
        var seen: Set<UUID> = [identity.member.id]
        return DeviceLogReader.peers(in: root)
            .compactMap { $0.manifest?.member }
            .filter { seen.insert($0.id).inserted }
    }

    /// Who deleted or moved a file nobody else has claimed.
    ///
    /// Every Mac whose app was running when it happened would have said so, so
    /// those are ruled out; if only this one is left, it was us. One found in the
    /// history replayed after a restart happened while nobody here was watching,
    /// at a time nobody knows, and stays without a name.
    private func resolveUnclaimed(_ entry: Entry) async -> UUID? {
        guard entry.event?.backfilled != true else { return nil }
        let verdict = resolver.inferBackfill(changeAt: entry.createdAt,
                                             selfMember: identity.member.id,
                                             selfAwake: [], peers: await peerAwareness())
        switch verdict {
        case .local: return identity.member.id
        case .inferred(let member): return member
        case .incoming, .unknown: return nil
        }
    }

    private func fileSize(of url: URL) throws -> Int64? {
        (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    // MARK: - What people write

    @discardableResult
    public func post(text: String, nodeID: UUID? = nil, isTask: Bool = false,
                     assignee: UUID? = nil, categories: Set<UUID> = [],
                     replyTo: UUID? = nil) async throws -> Entry {
        let now = clock.now
        let entry = Entry(projectID: projectID, nodeID: nodeID, authorID: identity.member.id,
                          createdAt: now, observedAt: now, kind: .message,
                          text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          isTask: isTask, assigneeID: assignee, replyToID: replyTo,
                          categoryIDs: categories)
        try store.merge(entry: entry)
        await record([.entry(EntryRecord(entry: entry))])
        return entry
    }

    public func patch(_ patch: EntryPatchRecord) async throws {
        let now = clock.now
        try store.apply(patch: patch, at: now)
        await record([.entryPatch(patch)])
    }

    public func announceSelf() async throws {
        await record([.member(identity.member)])
    }

    /// Somebody changed their own name or colour. The engine used to keep the
    /// person it was started with, so announcing the change sent the old name
    /// again — and the manifest, which the other Mac reads before any record,
    /// kept putting the old name back until the app was restarted.
    public func update(member: Member) async throws {
        guard member.id == identity.member.id else { return }
        identity.member = member
        try await writer.update(member: member)
        await record([.member(member)])
    }

    public func publish(categories: [Category]) async throws {
        await record(categories.map { .category($0) })
    }

    public func setArchiveAfterDays(_ days: Int) {
        archiveAfterDays = days
        try? store.archiveDeletedNodes(olderThan: days, now: clock.now)
    }

    public func setExcluded(paths: Set<String>) throws {
        try store.setExcludedPaths(paths, for: projectID)
        exclusions = ExclusionRules(userExcludedPaths: paths)
    }

    public func rescan() async {
        await catchUp(trustingOwnAwakeWindows: false)
    }
}

private extension FileEventType {
    /// Changes that leave nothing on this disk to say who made them: a file
    /// that vanished, or one sync may have moved here on somebody else's behalf.
    var isUnwitnessable: Bool { self == .removed || self == .moved || self == .renamed }
}
