import Foundation

public struct ScannedItem: Sendable, Hashable {
    public var relativePath: String
    public var isDirectory: Bool
    public var contentModifiedAt: Date?
    public var fileSize: Int64?
    public var fileIdentifier: UInt64?
    /// False for an iCloud file whose bytes are not on this Mac. Its metadata is
    /// still accurate; only its content is elsewhere.
    public var isMaterialised: Bool
}

public struct ScanResult: Sendable {
    public var items: [ScannedItem] = []
    /// Files iCloud has not downloaded here. Counted so the UI can say why a
    /// preview is a plain icon instead of an image.
    public var placeholderCount = 0
    public var skipped: [String: ExclusionReason] = [:]
}

/// Walks a project folder without ever pulling content down from iCloud.
public struct FileScanner: Sendable {
    public var exclusions: ExclusionRules
    public init(exclusions: ExclusionRules) { self.exclusions = exclusions }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
        .fileIdentifierKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    public func scan(root: URL, isCancelled: @Sendable () -> Bool = { false }) -> ScanResult {
        var result = ScanResult()
        let rootPath = root.path(percentEncoded: false)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: FileScanner.keys,
            options: [.producesRelativePathURLs]) else { return result }

        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { return result }
            guard let relative = RelativePath.of(url.path(percentEncoded: false), under: rootPath)
                    ?? (url.relativePath.isEmpty ? nil : RelativePath.normalize(url.relativePath)),
                  !relative.isEmpty else { continue }

            let values = try? url.resourceValues(forKeys: Set(FileScanner.keys))
            let isPackage = DocumentPackage.isPackage(relative)
            let isDirectory = !isPackage && (values?.isDirectory ?? false)

            if let reason = exclusions.exclusion(forRelativePath: relative, isDirectory: isDirectory) {
                // Not descending into an excluded folder is what keeps a Resolve
                // cache with 200,000 files from costing anything at all.
                if isDirectory { enumerator.skipDescendants() }
                result.skipped[relative] = reason
                continue
            }

            var materialised = true
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus {
                materialised = status == .current
                if !materialised { result.placeholderCount += 1 }
            }

            var modifiedAt = values?.contentModificationDate
            var size = (values?.fileSize).map(Int64.init)
            if isPackage {
                // One document, not a folder to walk into.
                if values?.isDirectory == true { enumerator.skipDescendants() }
                (modifiedAt, size) = DocumentPackage.stamp(of: url)
            }

            result.items.append(ScannedItem(
                relativePath: relative,
                isDirectory: isDirectory,
                contentModifiedAt: modifiedAt,
                fileSize: size,
                fileIdentifier: values?.fileIdentifier,
                isMaterialised: materialised))
        }
        return result
    }
}

/// What a catch-up comparison found.
public struct ReconcileResult: Sendable {
    public var created: [ScannedItem] = []
    public var modified: [(node: Node, item: ScannedItem)] = []
    public var removed: [Node] = []
    public var moved: [(node: Node, item: ScannedItem)] = []
    public var unchanged = 0

    public var isEmpty: Bool {
        created.isEmpty && modified.isEmpty && removed.isEmpty && moved.isEmpty
    }
    public var changeCount: Int { created.count + modified.count + removed.count + moved.count }
}

/// Compares what is on disk against what we last indexed.
///
/// This runs when replaying events is impossible — the app was closed for days,
/// or the system dropped its history. A missed change is the worst outcome the
/// spec names, so this errs towards reporting rather than towards quiet.
public enum Reconciler {

    public static func compare(scanned: [ScannedItem], known: [Node],
                               knownIdentifiers: [UUID: UInt64] = [:]) -> ReconcileResult {
        var result = ReconcileResult()
        var knownByPath = Dictionary(known.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        var unmatched = knownByPath

        for item in scanned {
            guard let node = knownByPath[item.relativePath] else { continue }
            unmatched.removeValue(forKey: item.relativePath)
            if node.state != .present {
                // It was gone and is back: the same file returning to its old place
                // picks up its old history rather than starting a new one.
                result.created.append(item)
                continue
            }
            if item.isDirectory {
                result.unchanged += 1
                continue
            }
            if changed(node: node, item: item) {
                result.modified.append((node, item))
            } else {
                result.unchanged += 1
            }
        }

        let newItems = scanned.filter { knownByPath[$0.relativePath] == nil }
        // A file that vanished from one path and appeared at another with the same
        // file identifier was moved, not deleted and recreated — which is what
        // keeps its history attached.
        // Indexed by id first. Scanning `known` for each identifier instead made
        // this quadratic, which is invisible on a test folder and four minutes on
        // a client folder with fifty thousand files in it.
        let nodesByID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var identifierToNode: [UInt64: Node] = [:]
        for (id, identifier) in knownIdentifiers {
            if let node = nodesByID[id], unmatched[node.relativePath] != nil {
                identifierToNode[identifier] = node
            }
        }
        for item in newItems {
            if let identifier = item.fileIdentifier, let node = identifierToNode[identifier] {
                result.moved.append((node, item))
                unmatched.removeValue(forKey: node.relativePath)
                identifierToNode.removeValue(forKey: identifier)
            } else {
                result.created.append(item)
            }
        }

        result.removed = unmatched.values.filter { $0.state == .present }
        knownByPath.removeAll()
        return result
    }

    static func changed(node: Node, item: ScannedItem) -> Bool {
        if let known = node.contentModifiedAt, let found = item.contentModifiedAt {
            if abs(known.timeIntervalSince(found)) > 1 { return true }
        } else if node.contentModifiedAt != nil || item.contentModifiedAt != nil {
            return true
        }
        if let knownSize = node.fileSize, let foundSize = item.fileSize, knownSize != foundSize {
            return true
        }
        return false
    }
}
