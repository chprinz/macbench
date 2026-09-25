import Foundation

public enum ExclusionReason: Equatable, Sendable {
    case ownLog
    case hidden
    case temporary
    case applicationCache(String)
    case userExcluded(String)
}

/// Decides what never reaches the change stream.
///
/// This list is the difference between an app people keep open and one they
/// switch off after a week: Adobe, Affinity and Resolve write hundreds of cache
/// and lock files during ordinary work, and every one of them would otherwise
/// look like "someone changed something".
///
/// Shipped with the app and updated with it — nobody should have to maintain it.
/// Users only add their own folders on top.
public struct ExclusionRules: Sendable, Equatable {

    /// Folder names ignored wherever they appear, matched case-insensitively.
    public static let defaultDirectoryNames: Set<String> = [
        // Version control and package managers
        ".git", ".svn", ".hg", "node_modules", ".build", ".venv", "__pycache__",
        // System
        ".trash", ".trashes", ".spotlight-v100", ".fseventsd", ".documentrevisions-v100",
        ".temporaryitems", ".apdisk", "$recycle.bin", "system volume information",
        // Adobe
        "adobe premiere pro auto-save", "adobe premiere pro audio previews",
        "adobe premiere pro video previews", "adobe premiere pro captured audio",
        "adobe after effects auto-save", "auto-save", "media cache", "media cache files",
        "peak files", "adobe premiere pro preview files", "ae_cache", "cep_cache",
        // Affinity
        "autosave", ".affinityautosave",
        // DaVinci Resolve
        "cacheclip", "proxymedia", "optimized media", "render cache",
        ".gallery", "blackmagic raw cache", "resolveprojectcache",
        // Misc creative tools
        "capture one cache", "proxies", "previews.lrdata", "cache",
    ]

    /// File extensions that are always working files, never documents.
    public static let defaultExtensions: Set<String> = [
        "tmp", "temp", "swp", "swo", "lock", "idlk", "prlock", "aeplock",
        "crdownload", "download", "part", "partial", "!ut", "crswap",
    ]

    /// Extra folders the user excluded, as project-relative paths.
    public var userExcludedPaths: Set<String>
    public var directoryNames: Set<String>
    public var extensions: Set<String>

    public init(userExcludedPaths: Set<String> = [],
                directoryNames: Set<String> = ExclusionRules.defaultDirectoryNames,
                extensions: Set<String> = ExclusionRules.defaultExtensions) {
        self.userExcludedPaths = userExcludedPaths
        self.directoryNames = directoryNames
        self.extensions = extensions
    }

    /// `nil` means the path is watched.
    public func exclusion(forRelativePath path: String, isDirectory: Bool) -> ExclusionReason? {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }

        // Our own change log lives inside the watched folder. Without this it would
        // watch itself write, forever.
        if components[0] == LogLayout.directoryName { return .ownLog }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let lower = component.lowercased()

            if directoryNames.contains(lower), !isLast || isDirectory {
                return .applicationCache(component)
            }
            // Hidden entries. Covers .DS_Store, .localized and the .name.icloud
            // placeholders iCloud leaves behind for evicted files.
            if component.hasPrefix(".") { return .hidden }
            // InDesign locks (~doc.idlk), Office (~$doc.docx), editor swap files.
            if component.hasPrefix("~") { return .temporary }
            if component.hasSuffix("~") { return .temporary }
            if component == "Icon\r" || component == "Icon" { return .temporary }
        }

        if !isDirectory {
            let ext = (path as NSString).pathExtension.lowercased()
            if !ext.isEmpty, extensions.contains(ext) { return .temporary }
        }

        for excluded in userExcludedPaths where path == excluded || path.hasPrefix(excluded + "/") {
            return .userExcluded(excluded)
        }
        return nil
    }

    public func isExcluded(_ path: String, isDirectory: Bool) -> Bool {
        exclusion(forRelativePath: path, isDirectory: isDirectory) != nil
    }
}
