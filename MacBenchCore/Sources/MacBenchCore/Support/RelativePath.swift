import Foundation

/// Project-relative paths, in exactly one shape.
///
/// `URL.path` appends a trailing slash for directories, so the same folder can
/// arrive as "Layout" from one source and "Layout/" from another. Two spellings
/// of one path break every lookup that joins on it — a folder stops finding its
/// own files — so every path entering the index goes through here first.
public enum RelativePath {
    public static func normalize(_ path: some StringProtocol) -> String {
        var text = String(path)
        while text.hasSuffix("/") { text.removeLast() }
        while text.hasPrefix("/") { text.removeFirst() }
        return text
    }

    /// Turns an absolute path into a project-relative one, or `nil` if it is not
    /// inside the project at all.
    public static func of(_ absolute: String, under root: String) -> String? {
        let base = normalize(root)
        let target = normalize(absolute)
        guard target != base else { return nil }
        guard target.hasPrefix(base + "/") else { return nil }
        return normalize(target.dropFirst(base.count))
    }
}
