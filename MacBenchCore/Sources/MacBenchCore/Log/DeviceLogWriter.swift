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

        let manifestURL = dir.appending(path: LogLayout.manifestName)
        if let data = try? Data(contentsOf: manifestURL),
           var existing = try? JSONCoding.decoder().decode(LogManifest.self, from: data) {
            existing.member = identity.member
            existing.deviceName = identity.deviceName
            manifest = existing
        } else {
            manifest = LogManifest(deviceID: identity.deviceID, deviceName: identity.deviceName,
                                   member: identity.member, updatedAt: clock.now)
        }

        currentSegmentIndex = manifest.segments.count
        if currentSegmentIndex == 0 { currentSegmentIndex = 1 }
        let segURL = dir.appending(path: LogLayout.segmentName(currentSegmentIndex))
        currentSegmentBytes = (try? FileManager.default
            .attributesOfItem(atPath: segURL.path(percentEncoded: false))[.size] as? Int) .flatMap { $0 } ?? 0
    }

    public var deviceID: UUID { identity.deviceID }
    public var lastSequence: Int { manifest.lastSequence }

    @discardableResult
    public func append(_ bodies: [LogBody]) throws -> [LogRecord] {
        guard !bodies.isEmpty else { return [] }
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
            for body in bodies {
                manifest.lastSequence += 1
                let record = LogRecord(sequence: manifest.lastSequence, deviceID: identity.deviceID,
                                       writtenAt: clock.now, body: body)
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
}
