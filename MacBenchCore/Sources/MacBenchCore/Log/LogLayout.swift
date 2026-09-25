import Foundation

/// On-disk layout inside a project folder.
///
///     <project>/.macbench/
///       devices/
///         <device-uuid>/
///           manifest.json
///           000001.jsonl
///           000002.jsonl
///           read-state.json
///
/// The invariant that makes this safe on top of any file sync: **no file is ever
/// written by more than one machine.** Each device owns exactly its own folder.
/// There is nothing to merge, so there is nothing to conflict.
public enum LogLayout {
    public static let directoryName = ".macbench"
    public static let devicesDirectoryName = "devices"
    public static let manifestName = "manifest.json"
    public static let readStateName = "read-state.json"
    public static let segmentExtension = "jsonl"
    /// Small enough that an append re-uploads little, large enough that a busy day
    /// does not produce hundreds of files for the sync engine to track.
    public static let maxSegmentBytes = 256 * 1024

    public static func logDirectory(in root: URL) -> URL {
        root.appending(path: directoryName, directoryHint: .isDirectory)
    }

    public static func devicesDirectory(in root: URL) -> URL {
        logDirectory(in: root).appending(path: devicesDirectoryName, directoryHint: .isDirectory)
    }

    public static func deviceDirectory(in root: URL, device: UUID) -> URL {
        devicesDirectory(in: root).appending(path: device.uuidString, directoryHint: .isDirectory)
    }

    public static func segmentName(_ index: Int) -> String {
        String(format: "%06d.%@", index, segmentExtension)
    }

    public static func isSegment(_ name: String) -> Bool {
        name.hasSuffix("." + segmentExtension) && !name.hasPrefix(".")
    }

    /// The project a folder is part of, when it is not one itself: the nearest
    /// folder above it with a history in it.
    ///
    /// Two people adding different levels of the same folder — one "Projekt",
    /// the other only "Projekt/Layout" — end up with two histories that never
    /// meet. Each is complete and each looks fine, so nobody notices until an
    /// answer never arrives. Nil when the folder keeps a history of its own,
    /// because then it is the one the others are writing into.
    ///
    /// Asks only whether a path exists. The sandbox allows that above a folder
    /// somebody picked, where it would refuse a listing.
    public static func enclosingProjectRoot(of folder: URL) -> URL? {
        let fileManager = FileManager.default
        func keepsHistory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: devicesDirectory(in: url).path(percentEncoded: false),
                                          isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let start = folder.standardizedFileURL
        guard !keepsHistory(start) else { return nil }
        var candidate = start.deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            if keepsHistory(candidate) { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }
}

/// This machine's identity: which device it is and which person sits at it.
public struct LocalIdentity: Codable, Hashable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var member: Member

    public init(deviceID: UUID = UUID(), deviceName: String, member: Member) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.member = member
    }
}

public enum LogError: Error, LocalizedError, Sendable {
    case notWritable(path: String, underlying: String)
    case incompatibleFormat(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .notWritable(let path, let underlying):
            "Cannot write the change log at \(path): \(underlying)"
        case .incompatibleFormat(let found, let supported):
            "This log was written by a newer version of the app (format \(found), this build reads \(supported))."
        }
    }
}
