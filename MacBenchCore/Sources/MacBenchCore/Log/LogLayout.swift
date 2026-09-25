import Foundation
import IOKit

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

    /// The number in a segment's name, which is the order it was written in.
    public static func segmentIndex(_ name: String) -> Int? {
        guard isSegment(name) else { return nil }
        return Int(name.dropLast(segmentExtension.count + 1))
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
    /// The hardware this identity was made on. Nil in one written before it was
    /// recorded, which the first start then fills in.
    public var machineID: String?

    public init(deviceID: UUID = UUID(), deviceName: String, member: Member,
                machineID: String? = MachineID.current) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.member = member
        self.machineID = machineID
    }

    /// This identity as the machine it is running on should use it.
    ///
    /// Migration Assistant and a Time Machine restore onto a new Mac copy the
    /// identity along with everything else, and the old Mac usually goes on
    /// running. Two machines then write into one device folder — the one way the
    /// rule that no file is written by two machines can break, and it breaks
    /// silently: each overwrites the other's manifest and segments. A copy that
    /// finds itself on other hardware becomes a device of its own. The person
    /// stays the same; it is still them, on a new Mac.
    public func claimed(by machine: String?, name: @autoclosure () -> String?) -> LocalIdentity {
        guard let machine, machineID != machine else { return self }
        var claimed = self
        claimed.machineID = machine
        // Filling in a missing machine is not a move: nothing says where the
        // identity was made, and this is the only place it has been seen.
        guard machineID != nil else { return claimed }
        claimed.deviceID = UUID()
        if let name = name() { claimed.deviceName = name }
        return claimed
    }
}

/// The hardware's own identifier, which a copied disk does not carry along.
public enum MachineID {
    public static let current: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
                                               kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }()
}

public enum LogError: Error, LocalizedError, Sendable {
    case notWritable(path: String, underlying: String)
    case incompatibleFormat(found: Int, supported: Int)
    /// This Mac's own log is there but cannot be read, so it is not known which
    /// numbers are already spent.
    case ownLogUnavailable(path: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .notWritable(let path, let underlying):
            "Cannot write the change log at \(path): \(underlying)"
        case .incompatibleFormat(let found, let supported):
            "This log was written by a newer version of the app (format \(found), this build reads \(supported))."
        case .ownLogUnavailable(let path, let underlying):
            "This Mac's change log at \(path) cannot be read right now: \(underlying) Nothing is written to it until it can, so the other Macs do not miss a record. The app tries again every minute."
        }
    }
}
