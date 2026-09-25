import Foundation
import CryptoKit

/// Deterministic UUID version 5 (SHA-1, name-based).
///
/// Node identity has to be identical on every machine without any coordination:
/// two Macs that see the same file at the same relative path must derive the same
/// id, because there is no server to hand one out. Everything else in the log is
/// keyed off these ids.
public enum UUIDv5 {
    public static func make(namespace: UUID, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Fixed namespaces. Never change these values: doing so re-mints every id in
/// every existing log and silently detaches history from its files.
public enum Namespace {
    public static let node = UUID(uuidString: "6E9B1E4C-1F2A-5A7B-9C3D-4E5F60718293")!
    public static let category = UUID(uuidString: "1B7D3C90-55E2-5F14-8A66-0C2D9E4F7A31")!

    /// Node ids are derived from the path a node was *first* seen at, project-relative.
    /// Renames keep the original id and are recorded as rename records, so the id
    /// stays stable while the path moves.
    public static func nodeID(firstSeenPath: String) -> UUID {
        UUIDv5.make(namespace: node, name: firstSeenPath)
    }

    /// Built-in categories get stable ids so two machines that each create their
    /// defaults on first launch end up with one "Feedback", not two.
    public static func builtInCategoryID(slug: String) -> UUID {
        UUIDv5.make(namespace: category, name: slug)
    }
}
