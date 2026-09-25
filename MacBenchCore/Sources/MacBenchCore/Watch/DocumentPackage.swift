import Foundation

/// Documents that are folders on disk and one file to everybody who uses them.
///
/// A Pages document is a directory of previews, an index archive and a copy of
/// every image placed in it. Pages rewrites most of that on every save, and keeps
/// the images' original modification dates when it copies them in. Watched as a
/// folder, one afternoon on a text became forty lines about `Index.zip` and
/// `preview-micro.jpg` — with nobody's name on them, because a file whose date is
/// days old looks like it arrived through sync.
///
/// Decided by extension, never by asking the filesystem. Both Macs have to agree
/// on what a node is without talking, and a package iCloud has not downloaded
/// yet, or has just deleted, cannot answer the question at all.
public enum DocumentPackage {

    public static let extensions: Set<String> = [
        // iWork
        "pages", "key", "numbers",
        // Apple media and projects
        "rtfd", "fcpbundle", "logicx", "band", "imovielibrary", "photoslibrary",
        "theater", "motn", "moef",
        // Writing and diagrams
        "scriv", "graffle",
        // Bundles that turn up in shared folders
        "app", "bundle", "xcodeproj", "xcworkspace", "playground",
    ]

    public static func isPackage(_ relativePath: String) -> Bool {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return !ext.isEmpty && extensions.contains(ext)
    }

    /// The outermost package `relativePath` is, or lies inside. `nil` for an
    /// ordinary file or folder.
    public static func root(of relativePath: String) -> String? {
        var prefix = ""
        for component in relativePath.split(separator: "/") {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            if isPackage(prefix) { return prefix }
        }
        return nil
    }

    /// True for anything strictly inside a package.
    public static func isInside(_ relativePath: String) -> Bool {
        guard let root = root(of: relativePath) else { return false }
        return root != relativePath
    }

    /// The package's newest modification date and its total size.
    ///
    /// The folder's own date only moves when an entry is added or removed, and the
    /// images inside keep the dates they had before they were placed. The newest
    /// date anywhere in it is the moment somebody last saved.
    public static func stamp(of url: URL) -> (modifiedAt: Date?, size: Int64?) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        let own = try? url.resourceValues(forKeys: Set(keys))
        var latest = own?.contentModificationDate
        // Some of these extensions are flat files in older versions of their app.
        guard own?.isDirectory == true else { return (latest, (own?.fileSize).map(Int64.init)) }
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys) else { return (latest, nil) }
        while let child = enumerator.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if let modified = values.contentModificationDate, latest.map({ modified > $0 }) ?? true {
                latest = modified
            }
            if values.isDirectory != true { total += Int64(values.fileSize ?? 0) }
        }
        return (latest, total)
    }
}
