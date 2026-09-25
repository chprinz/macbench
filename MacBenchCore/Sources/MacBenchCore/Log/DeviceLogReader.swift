import Foundation

/// What one pass over the peers' logs produced, including everything that was
/// *not* readable. Silence is the failure mode this app cares about most, so the
/// reader reports missing and pending material explicitly rather than returning
/// a shorter list.
public struct LogReadResult: Sendable {
    public var records: [LogRecord] = []
    public var manifest: LogManifest?
    /// Highest sequence actually parsed from disk.
    public var lastSequence: Int = 0
    /// Sequence ranges the manifest promises but the segments do not contain.
    /// Almost always "sync has not caught up yet"; if they persist, data is lost.
    public var gaps: [ClosedRange<Int>] = []
    /// Segments that exist as iCloud placeholders. A download was requested.
    public var pendingDownloads: [String] = []
    public var unreadable: [String: String] = [:]
    public var incompatibleFormat: Int?

    public var isComplete: Bool {
        gaps.isEmpty && pendingDownloads.isEmpty && unreadable.isEmpty && incompatibleFormat == nil
    }
}

public struct PeerLog: Sendable {
    public var deviceID: UUID
    public var directory: URL
    public var manifest: LogManifest?
}

public enum DeviceLogReader {

    /// Every device folder found in the project, including this machine's own.
    ///
    /// Hidden items are **not** skipped. Everything here lives inside `.macbench`,
    /// and iCloud Drive reports what is inside a hidden folder as hidden too — so
    /// `.skipsHiddenFiles` returns an empty list there while the same folder read
    /// on a local disk returns every device. That is the failure mode this app
    /// exists to prevent: the other machine simply never appears, and nothing says
    /// why. A device folder is recognised by its name being a uuid, which is the
    /// only filter this needs.
    public static func peers(in root: URL) -> [PeerLog] {
        let devicesDir = LogLayout.devicesDirectory(in: root)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: devicesDir, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let manifestURL = url.appending(path: LogLayout.manifestName)
            ensureDownloaded(manifestURL)
            let manifest = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONCoding.decoder().decode(LogManifest.self, from: $0) }
            return PeerLog(deviceID: id, directory: url, manifest: manifest)
        }
        .sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
    }

    /// Reads a device's records with sequence greater than `after`.
    public static func read(peer: PeerLog, after: Int) -> LogReadResult {
        var result = LogReadResult()
        result.manifest = peer.manifest

        if let version = peer.manifest?.formatVersion, version > logFormatVersion {
            result.incompatibleFormat = version
            return result
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: peer.directory.path(percentEncoded: false)))?
            .filter(LogLayout.isSegment)
            .sorted() ?? []

        var seen = Set<Int>()
        for name in names {
            // Skip segments entirely below the watermark — on a two-year-old log
            // that is the difference between reading 40 MB and reading one file.
            if let seg = peer.manifest?.segments.first(where: { $0.name == name }), seg.lastSequence <= after {
                continue
            }
            let url = peer.directory.appending(path: name)
            if !ensureDownloaded(url) {
                result.pendingDownloads.append(name)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                result.unreadable[name] = "could not be read"
                continue
            }
            let (records, badLines) = parse(data, after: after)
            for record in records {
                seen.insert(record.sequence)
                result.records.append(record)
                result.lastSequence = max(result.lastSequence, record.sequence)
            }
            if let badLines { result.unreadable[name] = badLines }
        }

        result.records.sort { $0.sequence < $1.sequence }
        result.gaps = findGaps(seen: seen, after: after,
                               claimed: peer.manifest?.lastSequence ?? result.lastSequence)
        return result
    }

    /// Parses newline-delimited JSON, tolerating a truncated final line: while a
    /// segment is being appended to or is mid-upload, the tail can legitimately be
    /// half a record. Everything else that fails to parse is reported.
    static func parse(_ data: Data, after: Int) -> (records: [LogRecord], problem: String?) {
        let decoder = JSONCoding.decoder()
        var records: [LogRecord] = []
        var failures = 0
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let endsWithNewline = data.last == 0x0A
        if let last = lines.last, last.isEmpty { lines.removeLast() }

        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            let isFinal = index == lines.count - 1 && !endsWithNewline
            do {
                let record = try decoder.decode(LogRecord.self, from: Data(line))
                if record.sequence > after { records.append(record) }
            } catch {
                if isFinal { continue }  // partial tail, will be complete next pass
                failures += 1
            }
        }
        return (records, failures > 0 ? "\(failures) unreadable record(s)" : nil)
    }

    static func findGaps(seen: Set<Int>, after: Int, claimed: Int) -> [ClosedRange<Int>] {
        guard claimed > after else { return [] }
        var gaps: [ClosedRange<Int>] = []
        var runStart: Int?
        for seq in (after + 1)...claimed {
            if seen.contains(seq) {
                if let start = runStart { gaps.append(start...(seq - 1)); runStart = nil }
            } else if runStart == nil {
                runStart = seq
            }
        }
        if let start = runStart { gaps.append(start...claimed) }
        return gaps
    }

    /// True when the file's bytes are actually here. For an iCloud placeholder a
    /// download is kicked off and `false` returned, so the caller can report
    /// "waiting for sync" instead of "nothing happened".
    @discardableResult
    static func ensureDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]) else {
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
        guard values.isUbiquitousItem == true else {
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
        if values.ubiquitousItemDownloadingStatus == .current { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return false
    }
}
