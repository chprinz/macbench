import Foundation

/// Appends this device's records to its own segment files and keeps its manifest
/// current. Single writer by construction — see `LogLayout`.
public actor DeviceLogWriter {
    private let root: URL
    private var identity: LocalIdentity
    private let clock: any Clock
    private var manifest: LogManifest
    private var currentSegmentIndex: Int
    private var currentSegmentBytes: Int

    public init(root: URL, identity: LocalIdentity, clock: any Clock = SystemClock()) throws {
        self.root = root
        self.identity = identity
        self.clock = clock

        let dir = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw LogError.notWritable(path: dir.path(percentEncoded: false),
                                       underlying: error.localizedDescription)
        }

        // A manifest that is there but cannot be read is not a first start. An
        // evicted one on a Mac that was offline for months used to be taken for
        // one: numbering began at one again, the other Mac had long passed those
        // numbers, and it never read a single new record. Nothing is written
        // until the real one is here.
        let manifestURL = dir.appending(path: LogLayout.manifestName)
        var loaded = LogManifest(deviceID: identity.deviceID, deviceName: identity.deviceName,
                                 member: identity.member, updatedAt: clock.now)
        if FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) {
            DeviceLogReader.ensureDownloaded(manifestURL)
            let data: Data
            do {
                data = try Data(contentsOf: manifestURL)
            } catch {
                throw LogError.ownLogUnavailable(path: manifestURL.path(percentEncoded: false),
                                                 underlying: error.localizedDescription)
            }
            // Bytes that do not decode are a broken file of our own, and the
            // segments say everything it did. They are read in full below.
            if let existing = try? JSONCoding.decoder().decode(LogManifest.self, from: data) {
                loaded = existing
            }
        }
        loaded.member = identity.member
        loaded.deviceName = identity.deviceName

        // The segments are written before the manifest, so after a crash between
        // the two they are ahead of it. They are what decides which numbers are
        // spent.
        let before = loaded
        try Self.reconcile(&loaded, in: dir, manifestIsTrusted: loaded.lastSequence > 0)
        manifest = loaded
        if loaded.segments != before.segments || loaded.lastSequence != before.lastSequence {
            try? Self.write(loaded, to: dir)
        }

        currentSegmentIndex = manifest.segments.last.flatMap { LogLayout.segmentIndex($0.name) } ?? 1
        let segURL = dir.appending(path: LogLayout.segmentName(currentSegmentIndex))
        currentSegmentBytes = (try? FileManager.default
            .attributesOfItem(atPath: segURL.path(percentEncoded: false))[.size] as? Int) .flatMap { $0 } ?? 0
    }

    public var deviceID: UUID { identity.deviceID }
    public var lastSequence: Int { manifest.lastSequence }

    @discardableResult
    public func append(_ bodies: [LogBody]) throws -> [LogRecord] {
        let now = clock.now
        return try append(bodies.map { PendingRecord(body: $0, at: now) })
    }

    /// Records with the moment each happened, which may be earlier than now: a
    /// record that could not be written at the time keeps its own.
    @discardableResult
    public func append(_ pending: [PendingRecord]) throws -> [LogRecord] {
        guard !pending.isEmpty else { return [] }
        let dir = LogLayout.deviceDirectory(in: root, device: identity.deviceID)
        var written: [LogRecord] = []
        var payload = Data()
        var first = manifest.lastSequence + 1
        // A number is spent only once its record is on disk. Handing out numbers
        // for records that never got there left the manifest promising a
        // sequence no segment holds: a gap that never closes, and the other
        // Mac's watermark parked at it for good.
        var onDisk = manifest.lastSequence

        do {
            for item in pending {
                manifest.lastSequence += 1
                let record = LogRecord(sequence: manifest.lastSequence, deviceID: identity.deviceID,
                                       writtenAt: item.at, body: item.body)
                var line = try JSONCoding.encoder().encode(record)
                line.append(0x0A)
                // Rotate before the segment grows past the cap, so one record never
                // straddles two files.
                if currentSegmentBytes + payload.count + line.count > LogLayout.maxSegmentBytes,
                   currentSegmentBytes + payload.count > 0 {
                    try flush(payload, to: dir, firstSequence: first, lastSequence: manifest.lastSequence - 1)
                    onDisk = manifest.lastSequence - 1
                    payload = Data()
                    currentSegmentIndex += 1
                    currentSegmentBytes = 0
                    first = manifest.lastSequence
                }
                payload.append(line)
                written.append(record)
            }
            try flush(payload, to: dir, firstSequence: first, lastSequence: manifest.lastSequence)
        } catch {
            manifest.lastSequence = onDisk
            throw error
        }
        try writeManifest(to: dir)
        return written
    }

    /// A new name or colour for the person at this Mac. The manifest carries the
    /// person as well as the records do, and the other Mac reads it before any
    /// record on every pass — so a manifest left on the old name put it back each
    /// time.
    public func update(member: Member) throws {
        identity.member = member
        manifest.member = member
        try writeManifest(to: LogLayout.deviceDirectory(in: root, device: identity.deviceID))
    }

    /// Records that this device is awake right now, extending the current stretch
    /// or starting a new one. Cheap, because it lives in the manifest that gets
    /// rewritten anyway rather than as records in the stream.
    public func recordHeartbeat(now: Date? = nil, closing: Bool = false) throws {
        let stamp = now ?? clock.now
        let gapTolerance: TimeInterval = 30 * 60
        if var last = manifest.awakeWindows.last,
           stamp.timeIntervalSince(last.to) <= gapTolerance, stamp >= last.from {
            last.to = stamp
            manifest.awakeWindows[manifest.awakeWindows.count - 1] = last
        } else {
            manifest.awakeWindows.append(AwakeWindow(from: stamp, to: stamp))
        }
        // Ninety days is well past the point where anyone asks who changed a file.
        let cutoff = stamp.addingTimeInterval(-90 * 24 * 3600)
        manifest.awakeWindows.removeAll { $0.to < cutoff }
        _ = closing
        try writeManifest(to: LogLayout.deviceDirectory(in: root, device: identity.deviceID))
    }

    public func awakeWindows() -> [AwakeWindow] { manifest.awakeWindows }

    private func flush(_ payload: Data, to dir: URL, firstSequence: Int, lastSequence: Int) throws {
        guard !payload.isEmpty else { return }
        let url = dir.appending(path: LogLayout.segmentName(currentSegmentIndex))
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                do {
                    try handle.write(contentsOf: payload)
                    // Records are worth an fsync: a half-written tail after a power
                    // cut is recoverable, a lost tail is a silent gap.
                    try handle.synchronize()
                } catch {
                    // Half a record at the end is a tail the reader waits out. With
                    // the next append behind it, it is a broken line in the middle,
                    // and it takes the first record of that append down with it.
                    try? handle.truncate(atOffset: end)
                    throw error
                }
            } else {
                try payload.write(to: url, options: .atomic)
            }
        } catch {
            throw LogError.notWritable(path: url.path(percentEncoded: false),
                                       underlying: error.localizedDescription)
        }
        currentSegmentBytes += payload.count

        let name = LogLayout.segmentName(currentSegmentIndex)
        let count = payload.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
        if let idx = manifest.segments.firstIndex(where: { $0.name == name }) {
            manifest.segments[idx].lastSequence = lastSequence
            manifest.segments[idx].recordCount += count
        } else {
            manifest.segments.append(.init(name: name, firstSequence: firstSequence,
                                           lastSequence: lastSequence, recordCount: count))
        }
    }

    private func writeManifest(to dir: URL) throws {
        manifest.updatedAt = clock.now
        try Self.write(manifest, to: dir)
    }

    private static func write(_ manifest: LogManifest, to dir: URL) throws {
        let url = dir.appending(path: LogLayout.manifestName)
        do {
            let encoder = JSONCoding.encoder()
            encoder.outputFormatting.insert(.prettyPrinted)
            try encoder.encode(manifest).write(to: url, options: .atomic)
        } catch {
            throw LogError.notWritable(path: url.path(percentEncoded: false),
                                       underlying: error.localizedDescription)
        }
    }

    /// Brings the manifest up to what the segments on disk hold.
    ///
    /// Segments the manifest lists and has closed are taken at its word; on a
    /// long log that is the difference between reading one file and reading all
    /// of them. The last one it lists, and any it does not know, are read. When
    /// the manifest was lost that is every segment, which is what a rebuild is.
    ///
    /// A half-written record at the end of the last segment is cut off. The next
    /// append would land behind it and turn it into a broken line in the middle,
    /// taking the first new record down with it — a gap the other Mac waits at
    /// for good. Its number was never spent: the manifest is written after the
    /// segment, and only whole records are counted.
    ///
    /// A segment that cannot be read stops the writer, with one exception: the
    /// last one a readable manifest lists. The manifest already knows it, and an
    /// evicted file on a Mac that is offline is no reason to stop watching.
    static func reconcile(_ manifest: inout LogManifest, in dir: URL,
                          manifestIsTrusted: Bool) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
                .filter(LogLayout.isSegment).sorted()
        } catch {
            throw LogError.ownLogUnavailable(path: dir.path(percentEncoded: false),
                                             underlying: error.localizedDescription)
        }
        let listed = Set(manifest.segments.map(\.name))
        let lastListed = manifest.segments.last?.name
        for name in names where !listed.contains(name) || name == lastListed {
            let url = dir.appending(path: name)
            DeviceLogReader.ensureDownloaded(url)
            var data: Data
            do {
                data = try Data(contentsOf: url)
            } catch where manifestIsTrusted && name == lastListed {
                continue
            } catch {
                throw LogError.ownLogUnavailable(path: url.path(percentEncoded: false),
                                                 underlying: error.localizedDescription)
            }
            if name == names.last, let last = data.last, last != 0x0A {
                let keep = (data.lastIndex(of: 0x0A).map { $0 + 1 }) ?? data.startIndex
                do {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: UInt64(keep - data.startIndex))
                    try handle.synchronize()
                } catch {
                    throw LogError.notWritable(path: url.path(percentEncoded: false),
                                               underlying: error.localizedDescription)
                }
                data = data[..<keep]
            }
            let sequences = DeviceLogReader.parse(data, after: 0).records.map(\.sequence)
            guard let first = sequences.min(), let last = sequences.max() else { continue }
            let segment = LogManifest.Segment(name: name, firstSequence: first, lastSequence: last,
                                              recordCount: sequences.count)
            if let index = manifest.segments.firstIndex(where: { $0.name == name }) {
                manifest.segments[index] = segment
            } else {
                manifest.segments.append(segment)
            }
            manifest.lastSequence = max(manifest.lastSequence, last)
        }
        manifest.segments.sort { $0.name < $1.name }
    }
}
