import Foundation
import GRDB

/// A project as this Mac keeps it: which folder, how to open it again, and how
/// much of it the person here wants to see. Nothing in it is shared.
public struct SavedProject: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isArchived: Bool
    public var addedAt: Date
    public var sortIndex: Int
    public var rootPath: String?
    public var rootBookmark: Data?
    public var verbosity: String
    public var excludedPaths: [String]
}

/// Which folders this Mac watches, in a file of its own beside the index.
///
/// The same reasoning as `IdentityFile`. An index that cannot be opened is
/// rebuilt from the logs, and the logs are inside the folders — so the one
/// thing they cannot say is where the folders are. Without this the rebuilt
/// app came up empty and asked for every folder again.
///
/// A mirror, not the source: the index stays where projects are read and
/// written, and this follows it. It is only read when the index has no project
/// at all, which is a rebuilt one.
public struct ProjectsFile: Sendable {
    public static let fileName = "projects.json"
    public let url: URL

    public init(directory: URL) {
        url = directory.appending(path: Self.fileName)
    }

    /// Nil when there is no file or it does not decode.
    public func load() -> [SavedProject]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder().decode([SavedProject].self, from: data)
    }

    public func save(_ projects: [SavedProject]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONCoding.encoder()
        encoder.outputFormatting.formUnion([.prettyPrinted, .sortedKeys])
        try encoder.encode(projects).write(to: url, options: .atomic)
    }
}

extension Store {

    /// Every project, archived ones included, as the mirror keeps them.
    public func savedProjects() throws -> [SavedProject] {
        try read { db in
            try ProjectRow.order(Column("sortIndex"), Column("id")).fetchAll(db).map {
                SavedProject(id: $0.id, name: $0.name, isArchived: $0.isArchived, addedAt: $0.addedAt,
                             sortIndex: $0.sortIndex, rootPath: $0.rootPath,
                             rootBookmark: $0.rootBookmark, verbosity: $0.verbosity,
                             excludedPaths: $0.excluded.sorted())
            }
        }
    }

    /// Puts projects back under their own ids. Projects already here are left
    /// alone. The event cursor is not restored: the index behind it is gone, so
    /// the folder is looked at afresh, as when it was first added.
    @discardableResult
    public func restore(_ projects: [SavedProject]) throws -> Int {
        try write { db in
            var restored = 0
            for saved in projects where try !ProjectRow.exists(db, key: saved.id) {
                let excluded = String(decoding: try JSONEncoder().encode(saved.excludedPaths.sorted()),
                                      as: UTF8.self)
                try ProjectRow(id: saved.id, name: saved.name, isArchived: saved.isArchived,
                               addedAt: saved.addedAt, sortIndex: saved.sortIndex,
                               rootPath: saved.rootPath, rootBookmark: saved.rootBookmark,
                               verbosity: saved.verbosity, lastFSEventID: nil, lastScanAt: nil,
                               excludedPaths: excluded).insert(db)
                restored += 1
            }
            return restored
        }
    }
}
