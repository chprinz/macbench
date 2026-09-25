import Foundation

/// A record that was meant for this Mac's log, with the moment it happened.
public struct PendingRecord: Hashable, Sendable {
    public var body: LogBody
    public var at: Date

    public init(body: LogBody, at: Date) {
        self.body = body
        self.at = at
    }
}

/// What this Mac could not write to its log yet, kept until it can be.
///
/// A write that failed used to be gone for good. The index had the change, the
/// log did not, and the other Macs never learned of that file, rename or
/// message — while this one showed it as if it had been sent.
///
/// Kept beside the index rather than in the project folder, because the project
/// folder is what could not be written. Each record keeps the moment it
/// happened: changes to an entry are settled by their time on every Mac, and one
/// that arrives late must not overrule what somebody did in the meantime.
struct UnwrittenQueue {
    let url: URL
    private(set) var records: [PendingRecord] = []

    init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        // The log's own record format, numbered zero: the number is handed out
        // when it is written for real.
        records = DeviceLogReader.parse(data, after: -1).records.map {
            PendingRecord(body: $0.body, at: $0.writtenAt)
        }
    }

    var isEmpty: Bool { records.isEmpty }

    mutating func replace(with records: [PendingRecord]) {
        self.records = records
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var data = Data()
        let encoder = JSONCoding.encoder()
        for record in records {
            let line = LogRecord(sequence: 0, deviceID: UUID(), writtenAt: record.at, body: record.body)
            guard let encoded = try? encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
