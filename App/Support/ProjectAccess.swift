import Foundation
import MacBenchCore

/// Holds the sandbox permissions for the folders the user picked.
///
/// A bookmark is bound to this Mac and contains the account name, which is why it
/// is stored locally and never travels in the log.
@MainActor
final class ProjectAccess {
    private var active: [UUID: URL] = [:]

    enum Failure: LocalizedError {
        case bookmarkStale(String)
        case noAccess(String)

        var errorDescription: String? {
            switch self {
            case .bookmarkStale(let name):
                String(localized: "Lost access to “\(name)”. Choose the folder again to restore it.")
            case .noAccess(let name):
                String(localized: "Cannot open “\(name)”. The folder may have been moved, or it is on a volume that is not connected.")
            }
        }
    }

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves and starts access. The returned URL stays usable until `release`.
    @discardableResult
    func open(project: Project, bookmark: Data?, fallbackPath: String?, store: Store) throws -> URL {
        if let url = active[project.id] { return url }

        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                active[project.id] = url
                if stale, let fresh = try? ProjectAccess.makeBookmark(for: url) {
                    // The folder moved but is still reachable: quietly re-point.
                    try? store.updateProjectLocation(project.id, path: url.path(percentEncoded: false),
                                                     bookmark: fresh)
                }
                return url
            }
            throw Failure.bookmarkStale(project.name)
        }

        // Only used in tests and for folders that need no scoped access.
        guard let fallbackPath else { throw Failure.noAccess(project.name) }
        let url = URL(fileURLWithPath: fallbackPath, isDirectory: true)
        active[project.id] = url
        return url
    }

    func release(project: UUID) {
        active.removeValue(forKey: project)?.stopAccessingSecurityScopedResource()
    }

    func releaseAll() {
        for url in active.values { url.stopAccessingSecurityScopedResource() }
        active.removeAll()
    }

    func url(for project: UUID) -> URL? { active[project] }
}
