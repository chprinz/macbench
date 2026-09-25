import Foundation

/// Who this Mac is, in a file of its own beside the index.
///
/// It used to live inside the index, and an index that cannot be opened is
/// deleted and rebuilt from the logs — taking with it the one thing the logs
/// cannot give back. The person onboarded again, got a new member id, and
/// appeared to the others as somebody new, while everything they had written
/// before stayed with a person nobody could be any more. Beside the index, a
/// rebuild keeps the device id too, so this Mac reads its own log back as well.
public struct IdentityFile: Sendable {
    public static let fileName = "identity.json"
    public let url: URL

    public init(directory: URL) {
        url = directory.appending(path: Self.fileName)
    }

    /// This Mac's identity. The one in the file if there is one; otherwise the
    /// one an older version kept in the index, which is moved into the file.
    /// Nil only when there is neither, which is a Mac that has not onboarded.
    ///
    /// A file that is there but does not decode falls back to the index rather
    /// than to onboarding: a new identity is the outcome this exists to avoid.
    public func load(orAdopt legacy: @autoclosure () -> LocalIdentity?) -> LocalIdentity? {
        if let data = try? Data(contentsOf: url),
           let identity = try? JSONCoding.decoder().decode(LocalIdentity.self, from: data) {
            return identity
        }
        guard let identity = legacy() else { return nil }
        try? save(identity)
        return identity
    }

    public func save(_ identity: LocalIdentity) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONCoding.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        try encoder.encode(identity).write(to: url, options: .atomic)
    }
}
