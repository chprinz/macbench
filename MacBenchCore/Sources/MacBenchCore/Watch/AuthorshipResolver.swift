import Foundation

public enum OriginVerdict: Sendable, Equatable {
    /// This machine's user made the change; the entry is written with their name.
    case local
    /// The change arrived through file sync. Only the machine it happened on may
    /// name an author, so this one records the change without one.
    case incoming
    /// Nobody witnessed it live, but only one person can have made it.
    case inferred(UUID)
    /// Recorded honestly as "changed, author unknown" rather than guessed at, and
    /// repaired later if the author's log turns up.
    case unknown

    public var authorIsSelf: Bool { self == .local }
}

/// Decides whether a change belongs to the person sitting at this Mac.
///
/// Getting this wrong is the failure the spec warns about: it cannot be seen on a
/// single machine, and it puts the wrong name on other people's work. So the
/// decision is made here, from explicit inputs, and covered by tests.
public struct AuthorshipResolver: Sendable {
    /// A file saved locally has a modification date of roughly now. Anything much
    /// older reached this Mac by another route.
    public var staleContentThreshold: TimeInterval = 120
    /// How long after a placeholder vanished we still treat a file as freshly
    /// materialised by sync.
    public var materialisationWindow: TimeInterval = 300

    public init() {}

    /// For a change observed while the app was running.
    public func assessLive(_ signals: FileOriginSignals) -> OriginVerdict {
        if signals.wasJustMaterialised { return .incoming }
        if signals.isDownloading || signals.isNotDownloaded { return .incoming }
        // Uploading means our machine is pushing this file out, which only happens
        // after a local write.
        if signals.isUploading { return .local }
        // A package arriving from the other Mac shows no download, and a save
        // made there a minute ago looks just like one made here — which put this
        // Mac's name on Pages documents the other person had created. In a
        // shared folder, iCloud's last editor settles it once the change has
        // waited for the other log; see `author(from:)`.
        if signals.isPackage, signals.isShared { return .incoming }
        if signals.contentAge > staleContentThreshold { return .incoming }
        return .local
    }

    /// For a change found by a catch-up scan, where nobody watched it happen.
    ///
    /// The inference: a machine that was running would have recorded its own
    /// user's edit. So every device that was awake at that moment and stayed
    /// silent can be ruled out, and if exactly one candidate is left, it was them.
    public func inferBackfill(changeAt date: Date, selfMember: UUID,
                              selfAwake: [AwakeWindow], peers: [PeerAwareness]) -> OriginVerdict {
        let weWereAwake = selfAwake.contains { $0.covers(date) }
        var candidates: Set<UUID> = weWereAwake ? [] : [selfMember]
        for peer in peers where !peer.windows.contains(where: { $0.covers(date) }) {
            candidates.insert(peer.memberID)
        }
        if candidates.count == 1, let only = candidates.first {
            return only == selfMember ? .local : .inferred(only)
        }
        return .unknown
    }
}

extension AuthorshipResolver {
    /// The person iCloud names as the last to edit a file, as one of the people in
    /// this project.
    ///
    /// `currentUser` is only taken at its word where it cannot be a leftover: for
    /// a change nobody watched happen, or one that has waited long enough for
    /// iCloud to have caught up. Seen live, a file arriving from the other Mac can
    /// still carry the previous editor for a moment — and if that was the person
    /// here, trusting it would put their name on somebody else's work.
    public func author(from editor: SharedEditor, selfMember: UUID, others: [Member],
                       trustCurrentUser: Bool) -> UUID? {
        switch editor {
        case .notShared: return nil
        case .currentUser: return trustCurrentUser ? selfMember : nil
        case .named(let name): return Self.member(named: name, among: others)
        }
    }

    /// Which of the other people an iCloud account name belongs to.
    ///
    /// People call themselves one thing in the app and another on their Apple
    /// account — "Mara" and "Mara Lindqvist", "Max" and "Maximilian Weber" — so a
    /// name matches on the full name, the first name, or the start of either. A
    /// name that is exactly somebody's beats one that only starts theirs. If
    /// nobody matches and there is only one other person, it is them: in a
    /// project of two there is nobody else it could be. Anything less certain
    /// stays without a name.
    public static func member(named name: PersonNameComponents, among others: [Member]) -> UUID? {
        let full = fold(PersonNameComponentsFormatter.localizedString(from: name, style: .default))
        let given = fold(name.givenName ?? "")
        let nick = fold(name.nickname ?? "")
        let exact = others.filter { [full, given, nick].contains(fold($0.name)) }
        if exact.count == 1 { return exact[0].id }
        guard exact.isEmpty else { return nil }
        let loose = others.filter { member in
            let own = fold(member.name)
            guard !own.isEmpty else { return false }
            return (!given.isEmpty && (given.hasPrefix(own) || own.hasPrefix(given)))
                || full.hasPrefix(own + " ")
        }
        if loose.count == 1 { return loose[0].id }
        if loose.isEmpty, others.count == 1 { return others[0].id }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

public struct PeerAwareness: Sendable, Hashable {
    public var memberID: UUID
    public var windows: [AwakeWindow]
    public init(memberID: UUID, windows: [AwakeWindow]) {
        self.memberID = memberID
        self.windows = windows
    }
}

/// Remembers which files iCloud materialised recently, so a change that lands a
/// second later can be recognised as somebody else's work.
public final class MaterialisationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Date] = [:]
    private let window: TimeInterval

    public init(window: TimeInterval = 300) { self.window = window }

    public func note(path: String, at date: Date) {
        lock.withLock {
            seen[path] = date
            if seen.count > 4_000 {
                let cutoff = date.addingTimeInterval(-window)
                seen = seen.filter { $0.value > cutoff }
            }
        }
    }

    public func wasRecentlyMaterialised(path: String, at date: Date) -> Bool {
        lock.withLock {
            guard let when = seen[path] else { return false }
            return date.timeIntervalSince(when) <= window
        }
    }
}
