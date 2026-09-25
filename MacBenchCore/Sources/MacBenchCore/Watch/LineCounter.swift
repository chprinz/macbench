import Foundation

public struct LineDelta: Sendable, Hashable {
    public var added: Int
    public var removed: Int
    public var isFirstSnapshot: Bool
}

/// Counts added and removed lines for small text files.
///
/// Everything else — a layout, a video, a raw photo — is reported as "replaced"
/// with no size given, because a byte count says nothing a person can act on.
public struct LineCounter: Sendable {
    /// Above this the file is not text worth diffing, whatever its extension says.
    public static let sizeLimit = 1_000_000

    private let snapshots: SnapshotStore

    public init(snapshotDirectory: URL) {
        snapshots = SnapshotStore(directory: snapshotDirectory)
    }

    /// `nil` when the file is not countable: too large, not text, or not on this
    /// Mac. Never downloads anything to find out.
    public func delta(for url: URL, nodeID: UUID, fileSize: Int64?) -> LineDelta? {
        if let fileSize, fileSize > LineCounter.sizeLimit { return nil }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= LineCounter.sizeLimit,
              looksLikeText(data) else { return nil }

        let hashes = lineHashes(data)
        defer { snapshots.store(hashes, for: nodeID) }
        guard let previous = snapshots.load(nodeID) else {
            return LineDelta(added: hashes.count, removed: 0, isFirstSnapshot: true)
        }

        var counts: [UInt64: Int] = [:]
        counts.reserveCapacity(max(previous.count, hashes.count))
        for hash in hashes { counts[hash, default: 0] += 1 }
        for hash in previous { counts[hash, default: 0] -= 1 }
        var added = 0, removed = 0
        for delta in counts.values {
            if delta > 0 { added += delta } else if delta < 0 { removed -= delta }
        }
        return LineDelta(added: added, removed: removed, isFirstSnapshot: false)
    }

    public func forget(_ nodeID: UUID) { snapshots.remove(nodeID) }

    /// A NUL byte in the first few kilobytes means binary. Crude, and the same
    /// test every diff tool uses.
    func looksLikeText(_ data: Data) -> Bool {
        !data.prefix(8_000).contains(0)
    }

    func lineHashes(_ data: Data) -> [UInt64] {
        var hashes: [UInt64] = []
        var hash: UInt64 = 0xcbf29ce484222325
        var started = false
        for byte in data {
            if byte == 0x0A {
                hashes.append(started ? hash : 0)
                hash = 0xcbf29ce484222325
                started = false
                continue
            }
            if byte == 0x0D { continue }
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            started = true
        }
        if started { hashes.append(hash) }
        return hashes
    }
}

/// Keeps one fingerprint per text file so the next change can be measured.
/// Fingerprints, not copies: eight bytes a line, and nothing readable on disk.
struct SnapshotStore: Sendable {
    let directory: URL

    private func url(_ nodeID: UUID) -> URL {
        directory.appending(path: nodeID.uuidString + ".lines")
    }

    func load(_ nodeID: UUID) -> [UInt64]? {
        guard let data = try? Data(contentsOf: url(nodeID)), !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
    }

    func store(_ hashes: [UInt64], for nodeID: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hashes.withUnsafeBufferPointer { buffer in
            try? Data(buffer: buffer).write(to: url(nodeID), options: .atomic)
        }
    }

    func remove(_ nodeID: UUID) {
        try? FileManager.default.removeItem(at: url(nodeID))
    }
}
